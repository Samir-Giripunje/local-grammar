import hmac
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from corrector import Cancelled, Corrector, Settings, Unusable

MODEL_ID = os.environ.get("GRAMMAR_MODEL", "mlx-community/Qwen3.5-2B-4bit")
PORT = int(os.environ.get("GRAMMAR_PORT", "8765"))
TOKEN = os.environ.get("GRAMMAR_TOKEN", "")
MAX_CHARS = 32000
MAX_BYTES = MAX_CHARS * 4 + 16000
DEADLINE_SECONDS = 45


def exit_when_orphaned():
    parent = os.getppid()
    while os.getppid() == parent:
        time.sleep(2)
    os._exit(0)


threading.Thread(target=exit_when_orphaned, daemon=True).start()
corrector = Corrector(MODEL_ID)
model_lock = threading.Lock()
request_lock = threading.Lock()
latest_request = 0


def next_request_id() -> int:
    global latest_request
    with request_lock:
        latest_request += 1
        return latest_request


def parse_request(body: str, content_type: str) -> tuple[str, Settings, dict]:
    """Plain text, or JSON {"text", "settings", "limits"} when the app sends per-model settings."""
    if not content_type.startswith("application/json"):
        return body, Settings(), {}
    request = json.loads(body)
    text = request["text"]
    if not isinstance(text, str):
        raise TypeError("text must be a string")
    return text, Settings.from_dict(request.get("settings") or {}), request.get("limits") or {}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            return self.reply(404, "not found")
        if not self.authorized():
            return self.reply(401, "unauthorized")
        self.reply(200, MODEL_ID)

    def do_POST(self):
        if self.path != "/correct":
            return self.reply(404, "not found")
        if not self.authorized():
            return self.reply(401, "unauthorized")
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            return self.reply(400, "missing or invalid Content-Length")
        if length < 0:
            return self.reply(400, "missing or invalid Content-Length")
        if length > MAX_BYTES:
            return self.reply(413, f"text longer than {MAX_CHARS} characters")
        try:
            body = self.rfile.read(length).decode("utf-8")
        except UnicodeDecodeError:
            return self.reply(400, "text is not valid UTF-8")
        try:
            text, settings, limits = parse_request(body, self.headers.get("Content-Type", ""))
        except (ValueError, TypeError) as problem:
            return self.reply(400, f"invalid request: {problem}")
        max_chars = min(int(limits.get("max_chars") or MAX_CHARS), MAX_CHARS)
        if len(text) > max_chars:
            return self.reply(413, f"text longer than {max_chars} characters")

        request_id = next_request_id()
        deadline = time.monotonic() + float(limits.get("time_limit") or DEADLINE_SECONDS)
        with model_lock:
            if request_id != latest_request:
                return self.reply(409, "superseded by a newer request")
            start = time.perf_counter()
            try:
                corrected = corrector.correct(
                    text,
                    should_stop=lambda: request_id != latest_request or time.monotonic() > deadline,
                    settings=settings,
                )
            except Unusable as problem:
                print(f"unusable output after {(time.perf_counter() - start) * 1000:.0f} ms", flush=True)
                return self.reply(422, str(problem))
            except Cancelled:
                timed_out = time.monotonic() > deadline
                reason = "deadline" if timed_out else "superseded"
                print(f"stopped after {(time.perf_counter() - start) * 1000:.0f} ms ({reason})", flush=True)
                return self.reply(504 if timed_out else 409, "took too long" if timed_out else "superseded")
        print(f"corrected {len(text)} chars in {(time.perf_counter() - start) * 1000:.0f} ms", flush=True)
        self.reply(200, corrected)

    def authorized(self) -> bool:
        return hmac.compare_digest(self.headers.get("X-Grammar-Token", ""), TOKEN)

    def reply(self, status: int, body: str):
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except BrokenPipeError:
            pass

    def log_message(self, format, *args):
        pass


def bind_server() -> ThreadingHTTPServer:
    for _ in range(10):
        try:
            return ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
        except OSError:
            time.sleep(0.5)
    return ThreadingHTTPServer(("127.0.0.1", PORT), Handler)


if __name__ == "__main__":
    try:
        corrector.correct("warm up the model")
    except (Unusable, Cancelled):
        # A weak model can fail the warm-up sentence; it should still serve (and fail visibly per request).
        print("warm-up produced no usable answer; serving anyway", flush=True)
    server = bind_server()
    print(f"serving {MODEL_ID} on 127.0.0.1:{PORT}", flush=True)
    server.serve_forever()
