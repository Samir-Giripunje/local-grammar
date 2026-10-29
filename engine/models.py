"""Model manager for the Local Grammar app: inspect, download, list, delete and test MLX models.

Run as `.venv/bin/python models.py <command> ...`. Stdout carries only JSON (one object, or one object per line
for `download`); every log, warning and progress bar goes to stderr.
"""

import argparse
import importlib.util
import io
import json
import os
import re
import shutil
import signal
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable, Iterable
from fnmatch import fnmatch
from pathlib import Path
from typing import Any

from huggingface_hub import constants, scan_cache_dir, snapshot_download
from huggingface_hub.errors import CacheNotFound, GatedRepoError, LocalEntryNotFoundError, RepositoryNotFoundError
from huggingface_hub.utils import disable_progress_bars, filter_repo_objects
from tqdm.std import tqdm

HUB = "https://huggingface.co"
TIMEOUT = 15
MB = 1000**2
GB = 1000**3
DISK_MARGIN = 1 * GB
RUNTIME_OVERHEAD = 300 * MB
PROGRESS_INTERVAL = 0.25

# What we download: weights mlx_lm can load (it only globs model*.safetensors), configs and tokenizer files.
ALLOW_PATTERNS = ["model*.safetensors", "*.json", "*.jinja", "*.txt", "*.model", "*.tiktoken"]
WEIGHTS_PATTERN = "model*.safetensors"
TEXT_PIPELINES = {
    "text-generation",
    "text2text-generation",
    "image-text-to-text",
    "video-text-to-text",
    "audio-text-to-text",
    "any-to-any",
    "conversational",
}
# Quantization schemes mlx_lm.utils.load_model knows how to load (None = MLX's own "quantization" block).
LOADABLE_QUANT_METHODS = {None, "awq", "gptq", "bitnet", "mxfp4", "mxfp8", "fp8", "compressed-tensors", "modelopt"}
QUANT_METHOD_BITS = {"mxfp4": 4, "mxfp8": 8, "fp8": 8, "bitnet": 2}
# Helper modules in mlx_lm.models that are not model architectures.
NON_ARCHITECTURES = {"base", "cache", "activations", "rope_utils", "switch_layers", "pipeline", "bitlinear_layers",
                     "gated_delta", "mla", "ssm"}
QUANT_SUFFIX = re.compile(
    r"[-_.](gguf|mlx|awq|gptq|bnb|exl2|onnx|dwq|mixed|bf16|fp16|fp8|fp32|int4|int8|w4a16|w8a8|[2-8]-?bits?|q\d(_k)?(_[msl])?)$",
    re.IGNORECASE,
)
REPO_PART = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

OFFLINE_MESSAGE = "Couldn't reach Hugging Face — check your connection"
NOT_FOUND_MESSAGE = "Couldn't find that model on Hugging Face"
GATED_MESSAGE = "This model is gated: it needs a Hugging Face login, which Local Grammar doesn't support yet."


# ---------------------------------------------------------------- output


class Output:
    """JSON writer bound to the real stdout; fd 1 itself is pointed at stderr so stray prints can't corrupt it."""

    def __init__(self) -> None:
        sys.stdout.flush()
        self.stream = os.fdopen(os.dup(1), "w", encoding="utf-8")
        os.dup2(2, 1)
        self.lock = threading.RLock()

    def emit(self, payload: dict) -> None:
        with self.lock:
            self.stream.write(json.dumps(payload, ensure_ascii=False) + "\n")
            self.stream.flush()


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def size_text(size: int) -> str:
    return f"{size / GB:.1f} GB" if size >= GB else f"{max(size, MB) / MB:.0f} MB"


# ---------------------------------------------------------------- ids and paths


def normalize_id(raw: str) -> str | None:
    """`org/name`, `https://huggingface.co/org/name/tree/main?x`, `hf.co/org/name/` ... -> `org/name`."""
    text = raw.strip().split("?")[0].split("#")[0]
    text = re.sub(r"^(https?://)?(www\.)?(huggingface\.co|hf\.co)/", "", text, flags=re.IGNORECASE)
    parts = [part for part in text.split("/") if part]
    if len(parts) < 2 or parts[0] in {"datasets", "spaces", "collections", "papers"}:
        return None
    org, name = parts[0], parts[1]
    if not all(REPO_PART.match(part) and "--" not in part and ".." not in part for part in (org, name)):
        return None
    return f"{org}/{name}"


def is_path_argument(raw: str) -> bool:
    return raw.startswith(("/", "~"))


def display_name(repo_id: str) -> str:
    name = repo_id.rstrip("/").split("/")[-1]
    return re.sub(r"\s+", " ", name.replace("-", " ").replace("_", " ")).strip()


def hub_cache() -> Path:
    return Path(constants.HF_HUB_CACHE).expanduser()


def converted_root() -> Path:
    return Path.home() / "Library" / "Application Support" / "LocalGrammar" / "models"


def converted_dir(repo_id: str) -> Path:
    org, name = repo_id.split("/")
    return converted_root() / f"{org}--{name}-4bit"


def converted_id(folder: Path) -> str:
    """`Qwen--Qwen3-0.6B-4bit` -> `Qwen/Qwen3-0.6B-4bit` (Hub ids never contain `--`)."""
    org, _, name = folder.name.partition("--")
    return f"{org}/{name}" if name else folder.name


def cache_repo_dir(repo_id: str) -> Path:
    org, name = repo_id.split("/")
    return hub_cache() / f"models--{org}--{name}"


def cached_snapshot(repo_id: str) -> Path | None:
    """The snapshot `main` points at in the local HF cache (or the newest one), if any."""
    repo_dir = cache_repo_dir(repo_id)
    ref = repo_dir / "refs" / "main"
    if ref.is_file():
        snapshot = repo_dir / "snapshots" / ref.read_text().strip()
        if snapshot.is_dir():
            return snapshot
    snapshots = [path for path in (repo_dir / "snapshots").glob("*") if path.is_dir()]
    return max(snapshots, key=lambda path: path.stat().st_mtime, default=None)


def installed_path(repo_id: str) -> Path | None:
    """A complete local copy of `repo_id`: the HF cache snapshot, else our converted folder of that name."""
    snapshot = cached_snapshot(repo_id)
    if snapshot is not None and is_complete(snapshot):
        return snapshot
    org, name = repo_id.split("/")
    for folder in (converted_root() / f"{org}--{name}", converted_dir(repo_id)):
        if is_complete(folder):
            return folder
    return None


def disk_size(path: Path) -> int:
    """Bytes on disk under `path`, following the HF cache's symlinks and counting each file once."""
    seen: set[tuple[int, int]] = set()
    total = 0
    for file in path.rglob("*"):
        try:
            info = file.stat()
        except OSError:
            continue
        if file.is_file() and (info.st_dev, info.st_ino) not in seen:
            seen.add((info.st_dev, info.st_ino))
            total += info.st_size
    return total


def existing_ancestor(path: Path) -> Path:
    while not path.exists() and path != path.parent:
        path = path.parent
    return path


# ---------------------------------------------------------------- local model folders


def read_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def is_complete(folder: Path) -> bool:
    """config.json plus every weight file the safetensors index names (or at least one, without an index)."""
    if not (folder / "config.json").is_file():
        return False
    index = read_json(folder / "model.safetensors.index.json")
    if shards := set((index.get("weight_map") or {}).values()):
        return all((folder / shard).is_file() for shard in shards)
    return any(path.is_file() for path in folder.glob(WEIGHTS_PATTERN))


def folder_has_chat_template(folder: Path) -> bool:
    if (folder / "chat_template.jinja").is_file() or (folder / "chat_template.json").is_file():
        return True
    return bool(read_json(folder / "tokenizer_config.json").get("chat_template"))


def architecture_supported(config: dict) -> bool:
    """Mirrors mlx_lm.utils._get_classes: apply its remapping tables, then look for an mlx_lm.models module."""
    model_type = config.get("model_type")
    if not isinstance(model_type, str) or not model_type:
        return False
    try:
        from mlx_lm.utils import MODEL_ARCHITECTURE_REMAPPING, MODEL_REMAPPING
    except ImportError:
        MODEL_ARCHITECTURE_REMAPPING, MODEL_REMAPPING = {}, {}
    architectures = config.get("architectures") or ()
    if isinstance(architectures, str):
        architectures = (architectures,)
    remapped = next(
        (MODEL_ARCHITECTURE_REMAPPING[key] for arch in architectures if (key := (model_type, arch)) in MODEL_ARCHITECTURE_REMAPPING),
        MODEL_REMAPPING.get(model_type, model_type),
    )
    if remapped in NON_ARCHITECTURES or "." in remapped:
        return False
    try:
        return importlib.util.find_spec(f"mlx_lm.models.{remapped}") is not None
    except (ImportError, ValueError):
        return False


# ---------------------------------------------------------------- Hugging Face API


class HubError(Exception):
    pass


class NotFound(HubError):
    pass


def hub_get(url: str) -> tuple[Any, str | None]:
    """GET JSON from the Hub; returns (data, next page URL)."""
    request = urllib.request.Request(url, headers={"User-Agent": "LocalGrammar/1.0", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            data = json.load(response)
            links = response.headers.get("Link") or ""
    except urllib.error.HTTPError as error:
        if error.code in (401, 404):
            raise NotFound(NOT_FOUND_MESSAGE) from error
        raise HubError(f"Hugging Face returned an error (HTTP {error.code}) — try again later") from error
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise HubError(OFFLINE_MESSAGE) from error
    except ValueError as error:
        raise HubError("Hugging Face sent an unexpected reply — try again later") from error
    next_page = re.search(r'<([^>]+)>;\s*rel="next"', links)
    return data, next_page.group(1) if next_page else None


def repo_files(repo_id: str) -> list[dict]:
    """Every file in the repo's main branch with its real size (follows the tree API's pagination)."""
    url: str | None = f"{HUB}/api/models/{repo_id}/tree/main?recursive=true"
    files: list[dict] = []
    for _ in range(50):
        if url is None:
            break
        page, url = hub_get(url)
        files += [entry for entry in page if entry.get("type") == "file"]
    return files


def model_info(repo_id: str) -> dict:
    expand = ["config", "library_name", "safetensors", "gated", "tags", "pipeline_tag", "cardData"]
    query = "&".join(f"expand[]={field}" for field in expand)
    info, _ = hub_get(f"{HUB}/api/models/{repo_id}?{query}")
    return info


def raw_config(repo_id: str) -> dict:
    """The full config.json (the API only returns a summary of it). Empty if unavailable."""
    try:
        data, _ = hub_get(f"{HUB}/{repo_id}/resolve/main/config.json")
    except HubError:
        return {}
    return data if isinstance(data, dict) else {}


def base_name(repo_id: str) -> str:
    name = repo_id.split("/")[-1]
    while (stripped := QUANT_SUFFIX.sub("", name)) != name:
        name = stripped
    return name


def find_alternative(repo_id: str) -> str | None:
    """The most downloaded mlx-community 4-bit build of the same model, if there is one."""
    base = base_name(repo_id)
    try:
        results, _ = hub_get(
            f"{HUB}/api/models?author=mlx-community&search={urllib.parse.quote(base)}&sort=downloads&limit=10"
        )
    except HubError:
        return None

    def rank(name: str) -> int:
        lowered = name.lower()
        if lowered == f"{base.lower()}-4bit":
            return 0
        if "4bit" in lowered:
            return 2 if any(tag in lowered for tag in ("dwq", "mixed", "awq")) else 1
        return 3

    candidates = [
        (rank(name), position, result["id"])
        for position, result in enumerate(results)
        if result.get("id") != repo_id
        and result.get("pipeline_tag") in TEXT_PIPELINES | {None}
        and base.lower() in (name := result["id"].split("/")[-1]).lower()
        and re.search(r"\dbit", name.lower())
    ]
    return min(candidates)[2] if candidates else None


# ---------------------------------------------------------------- inspect


def empty_report(model_id: str, reason: str) -> dict:
    return {
        "id": model_id,
        "name": display_name(model_id) if model_id else "",
        "verdict": "unsupported",
        "reasons": [reason],
        "model_type": None,
        "architecture_supported": False,
        "format": "other",
        "bits": None,
        "download_bytes": 0,
        "memory_bytes": 0,
        "converted_bytes": None,
        "gated": False,
        "pipeline_tag": None,
        "chat_template": False,
        "trust_remote_code": False,
        "alternative": None,
        "installed": False,
        "local_path": None,
    }


def quantization(config: dict) -> dict:
    text_config = config.get("text_config") if isinstance(config.get("text_config"), dict) else {}
    for source in (config, text_config):
        for key in ("quantization", "quantization_config"):
            if isinstance(source.get(key), dict):
                return source[key]
    return {}


def quant_bits(config: dict, tags: Iterable[str]) -> int | None:
    quant = quantization(config)
    if isinstance(quant.get("bits"), int):
        return quant["bits"]
    if bits := QUANT_METHOD_BITS.get(quant.get("quant_method")):
        return bits
    if quant.get("load_in_4bit"):
        return 4
    if quant.get("load_in_8bit"):
        return 8
    for tag in tags:
        if match := re.fullmatch(r"(\d)-bit", tag):
            return int(match.group(1))
    return None


def assess(
    model_id: str,
    files: dict[str, int],
    config: dict,
    *,
    tags: Iterable[str] = (),
    library: str | None = None,
    pipeline_tag: str | None = None,
    gated: bool = False,
    parameters: int | None = None,
    chat_template: bool = False,
) -> dict:
    """Turns what we know about a repo (or folder) into the inspect report, minus install state and alternative."""
    report = empty_report(model_id, "")
    reasons: list[str] = []
    warnings: list[str] = []

    weights = {path: size for path, size in files.items() if "/" not in path and fnmatch(path, WEIGHTS_PATTERN)}
    weight_bytes = sum(weights.values())
    has_gguf = any(path.lower().endswith(".gguf") for path in files)
    has_other_safetensors = any(path.endswith(".safetensors") for path in files)
    quant = quantization(config)
    quant_method = quant.get("quant_method") if quant else None
    bits = quant_bits(config, tags)
    is_mlx = "quantization" in config or "mlx" in tags or library == "mlx"
    model_type = config.get("model_type") if isinstance(config.get("model_type"), str) else None
    supported = architecture_supported(config)
    remote_code = bool(config.get("auto_map")) or bool(config.get("model_file"))
    chat_template = chat_template or any(path in ("chat_template.jinja", "chat_template.json") for path in files)

    if weights:
        file_format = "mlx" if is_mlx else "safetensors"
    elif has_other_safetensors:
        file_format = "safetensors"
    else:
        file_format = "gguf" if has_gguf else "other"

    if gated:
        reasons.append(GATED_MESSAGE)
    if pipeline_tag and pipeline_tag not in TEXT_PIPELINES:
        kind = pipeline_tag.replace("-", " ")
        reasons.append(f"This is a {kind} model, not a text-generation model, so it can't proofread.")
    if not weights:
        if has_gguf and not has_other_safetensors:
            reasons.append("This repo only has GGUF files, which are for llama.cpp/Ollama — MLX can't load them.")
        elif has_other_safetensors:
            reasons.append("Its safetensors files aren't laid out the way MLX expects (model*.safetensors).")
        else:
            reasons.append("It has no safetensors weights (only PyTorch, ONNX or other formats), which MLX can't load.")
    if model_type is None:
        if weights:
            reasons.append("It has no usable config.json, so its architecture is unknown.")
    elif not supported:
        if remote_code:
            reasons.append("It needs custom code (trust_remote_code) to run, which isn't supported.")
        else:
            reasons.append(f"Its architecture ({model_type}) isn't supported by MLX yet.")
    elif config.get("model_file"):
        reasons.append("It needs custom code (trust_remote_code) to run, which isn't supported.")
    if quant and quant_method not in LOADABLE_QUANT_METHODS and "quantization" not in config:
        reasons.append(f"It uses {quant_method or 'an unknown'} quantization, which MLX can't load.")

    quantized = bits is not None
    converted_bytes = None
    if reasons:
        verdict = "unsupported"
    elif quantized:
        verdict = "ready"
    else:
        verdict = "convert"
        converted_bytes = int(parameters * 4.5 / 8) if parameters else int(weight_bytes * 4.5 / 16)
        reasons.append(
            f"Full-size weights ({size_text(weight_bytes)}). Will be shrunk to 4-bit while installing "
            f"(~{size_text(converted_bytes)})."
        )
    if verdict != "unsupported" and not chat_template:
        warnings.append("Looks like a base model — it may not follow proofreading instructions.")

    loaded_bytes = converted_bytes if converted_bytes is not None else weight_bytes
    memory_bytes = int(loaded_bytes * 1.15 + RUNTIME_OVERHEAD) if loaded_bytes else 0
    ram = ram_bytes()
    if verdict != "unsupported" and ram and memory_bytes > ram * 0.75:
        warnings.append(f"Needs about {size_text(memory_bytes)} of memory; this Mac has {size_text(ram)}.")

    report.update(
        verdict=verdict,
        reasons=reasons + warnings,
        model_type=model_type,
        architecture_supported=supported,
        format=file_format,
        bits=bits,
        download_bytes=sum(size for path, size in files.items() if matches_download(path)),
        memory_bytes=memory_bytes,
        converted_bytes=converted_bytes,
        gated=gated,
        pipeline_tag=pipeline_tag,
        chat_template=chat_template,
        trust_remote_code=remote_code,
    )
    return report


def matches_download(path: str) -> bool:
    return any(True for _ in filter_repo_objects([path], allow_patterns=ALLOW_PATTERNS))


def inspect_remote(model_id: str) -> dict:
    info = model_info(model_id)
    model_id = info.get("id") or model_id
    entries = repo_files(model_id)
    files = {entry["path"]: int(entry.get("size") or 0) for entry in entries}
    config = info.get("config") if isinstance(info.get("config"), dict) else {}
    gated = info.get("gated") not in (False, None)
    if not gated and "config.json" in files:
        config = {**config, **raw_config(model_id)}
    summary = info.get("config") or {}
    tokenizer_config = summary.get("tokenizer_config") or {}
    safetensors = info.get("safetensors") or {}
    report = assess(
        model_id,
        files,
        config,
        tags=info.get("tags") or [],
        library=info.get("library_name"),
        pipeline_tag=info.get("pipeline_tag"),
        gated=gated,
        parameters=safetensors.get("total"),
        chat_template=bool(tokenizer_config.get("chat_template") or summary.get("chat_template_jinja")),
    )
    report["name"] = display_name(model_id)
    if report["verdict"] == "convert":
        local = converted_dir(model_id)
        report["installed"] = is_complete(local)
    else:
        local = cached_snapshot(model_id)
        report["installed"] = local is not None and is_complete(local)
    report["local_path"] = str(local) if report["installed"] else None
    if report["verdict"] != "ready":
        report["alternative"] = find_alternative(model_id)
        if report["alternative"] and report["verdict"] == "unsupported":
            report["reasons"].append(f"Try {report['alternative']} instead.")
    return report


def inspect_folder(folder: Path) -> dict:
    if not (folder / "config.json").is_file():
        return empty_report(str(folder), "That folder doesn't contain a model (no config.json).")
    files = {
        str(path.relative_to(folder)): path.stat().st_size
        for path in folder.rglob("*")
        if path.is_file() and ".cache" not in path.parts
    }
    tags = ["mlx"] if "quantization" in read_json(folder / "config.json") else []
    report = assess(str(folder), files, read_json(folder / "config.json"), tags=tags,
                    chat_template=folder_has_chat_template(folder))
    if report["verdict"] == "convert":
        # A folder is used as is: MLX runs full-size weights too, it just needs more memory.
        weight_bytes = sum(size for path, size in files.items() if "/" not in path and fnmatch(path, WEIGHTS_PATTERN))
        report.update(verdict="ready", converted_bytes=None, memory_bytes=int(weight_bytes * 1.15 + RUNTIME_OVERHEAD))
        report["reasons"][0] = f"Full-size weights ({size_text(weight_bytes)}) — needs more memory than a 4-bit build."
    report["name"] = display_name(converted_id(folder))
    report["installed"] = report["verdict"] != "unsupported" and is_complete(folder)
    report["local_path"] = str(folder)
    return report


def cmd_inspect(out: Output, raw: str) -> int:
    if is_path_argument(raw):
        out.emit(inspect_folder(Path(raw).expanduser().resolve()))
        return 0
    model_id = normalize_id(raw)
    if model_id is None:
        out.emit(empty_report(raw.strip(), "That doesn't look like a Hugging Face model link or id (org/name)."))
        return 0
    try:
        out.emit(inspect_remote(model_id))
    except HubError as error:
        report = empty_report(model_id, str(error))
        if (local := installed_path(model_id)) is not None:
            report.update(installed=True, local_path=str(local))
        out.emit(report)
    except Exception as error:  # noqa: BLE001 — the app needs a JSON answer no matter what
        log(f"inspect failed: {error!r}")
        out.emit(empty_report(model_id, f"Something went wrong while checking this model: {error}"))
    return 0


# ---------------------------------------------------------------- download


def blob_progress(repo_id: str, wanted: list[dict]) -> Callable[[], int]:
    """Returns a function measuring how many of the wanted files' bytes are in the cache (finished or partial)."""
    blobs = cache_repo_dir(repo_id) / "blobs"
    expected = {(entry.get("lfs") or {}).get("oid") or entry["oid"]: int(entry.get("size") or 0) for entry in wanted}

    def measure() -> int:
        # Finished blobs are named by etag (often symlinks into the shared store); partial ones `<etag>[.<id>].incomplete`.
        present: dict[str, int] = {}
        try:
            entries = list(os.scandir(blobs))
        except OSError:
            return 0
        for entry in entries:
            etag = entry.name.split(".")[0]
            if etag in expected:
                try:
                    present[etag] = max(present.get(etag, 0), entry.stat().st_size)
                except OSError:
                    continue
        return sum(min(size, present.get(etag, 0)) for etag, size in expected.items())

    return measure


class NetworkBytes(tqdm):
    """Invisible progress bar handed to snapshot_download, used to read how many bytes arrived over the network.

    Xet writes partial files in big bursts, so polling the cache alone would make the progress bar jump.
    """

    bars: list["NetworkBytes"] = []

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        kwargs.update(file=io.StringIO(), disable=False, mininterval=3600)
        kwargs.pop("name", None)
        super().__init__(*args, **kwargs)
        NetworkBytes.bars.append(self)

    @classmethod
    def received(cls) -> int:
        return int(sum(bar.n for bar in list(cls.bars) if str(bar.desc).startswith("Downloading bytes")))


def report_progress(out: Output, measure: Callable[[], int], total: int, stop: threading.Event, last: int) -> None:
    baseline = last
    while not stop.wait(PROGRESS_INTERVAL):
        try:
            done = min(max(measure(), baseline + NetworkBytes.received(), last), total)
        except Exception:  # noqa: BLE001 — progress is best effort
            continue
        if done != last:
            out.emit({"phase": "downloading", "done": done, "total": total})
            last = done


def delete_from_cache(repo_id: str) -> int:
    """Removes every cached revision of `repo_id`; returns the bytes freed."""
    try:
        cache = scan_cache_dir(hub_cache())
    except CacheNotFound:
        return 0
    repo = next((r for r in cache.repos if r.repo_type == "model" and r.repo_id.lower() == repo_id.lower()), None)
    if repo is None or not repo.revisions:
        folder = cache_repo_dir(repo_id)
        if not folder.is_dir():
            return 0
        freed = disk_size(folder)
        shutil.rmtree(folder, ignore_errors=True)
        return freed
    strategy = cache.delete_revisions(*(revision.commit_hash for revision in repo.revisions))
    strategy.execute()
    shutil.rmtree(repo.repo_path, ignore_errors=True)  # leftover .incomplete files, locks, empty dirs
    return int(strategy.expected_freed_size)


def convert_to_4bit(source: Path, destination: Path) -> None:
    from mlx_lm import convert

    partial = destination.with_name(destination.name + ".partial")
    shutil.rmtree(partial, ignore_errors=True)
    partial.parent.mkdir(parents=True, exist_ok=True)
    convert(str(source), mlx_path=str(partial), quantize=True, q_bits=4, q_group_size=64)
    shutil.rmtree(destination, ignore_errors=True)
    partial.rename(destination)


def download_error(error: Exception) -> str:
    if isinstance(error, GatedRepoError):
        return GATED_MESSAGE
    if isinstance(error, RepositoryNotFoundError):
        return NOT_FOUND_MESSAGE
    if isinstance(error, LocalEntryNotFoundError):
        return OFFLINE_MESSAGE
    if isinstance(error, OSError) and error.errno == 28:
        return "The disk filled up while downloading — free some space and try again"
    return f"Download failed: {error}"


def cmd_download(out: Output, raw: str, convert: bool) -> int:
    def fail(message: str) -> int:
        out.emit({"phase": "error", "message": message})
        return 1

    def cancel(signum: int, frame: object) -> None:
        out.emit({"phase": "cancelled"})
        os._exit(130)

    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)

    repo_id = normalize_id(raw)
    if repo_id is None:
        return fail("That doesn't look like a Hugging Face model link or id (org/name).")
    if convert and is_complete(destination := converted_dir(repo_id)):
        out.emit({"phase": "done", "id": converted_id(destination), "path": str(destination)})
        return 0

    try:
        info, _ = hub_get(f"{HUB}/api/models/{repo_id}?expand[]=gated")
        if info.get("gated") not in (False, None):
            return fail(GATED_MESSAGE)
        repo_id = info.get("id") or repo_id  # the Hub's canonical spelling, so the cache folder name matches
        wanted = [entry for entry in repo_files(repo_id) if matches_download(entry["path"])]
    except HubError as error:
        return fail(str(error))
    destination = converted_dir(repo_id)
    total = sum(int(entry.get("size") or 0) for entry in wanted)
    if not any(fnmatch(entry["path"], WEIGHTS_PATTERN) for entry in wanted):
        return fail("This model has no MLX-compatible weights (model*.safetensors) to download.")

    measure = blob_progress(repo_id, wanted)
    weight_bytes = sum(int(entry.get("size") or 0) for entry in wanted if fnmatch(entry["path"], WEIGHTS_PATTERN))
    needed = total - min(measure(), total) + (int(weight_bytes * 4.5 / 16) if convert else 0)
    free = shutil.disk_usage(existing_ancestor(hub_cache())).free
    if needed + DISK_MARGIN > free:
        return fail(f"Not enough disk space: needs {size_text(needed + DISK_MARGIN)}, {size_text(free)} free")

    done = min(measure(), total)
    out.emit({"phase": "downloading", "done": done, "total": total})
    stop = threading.Event()
    reporter = threading.Thread(target=report_progress, args=(out, measure, total, stop, done), daemon=True)
    reporter.start()
    try:
        snapshot = Path(snapshot_download(repo_id, allow_patterns=ALLOW_PATTERNS, tqdm_class=NetworkBytes))
    except Exception as error:  # noqa: BLE001 — every failure becomes an error line
        log(f"download failed: {error!r}")
        return fail(download_error(error))
    finally:
        stop.set()
        reporter.join()
    out.emit({"phase": "downloading", "done": total, "total": total})

    if not convert:
        out.emit({"phase": "done", "id": repo_id, "path": str(snapshot)})
        return 0

    out.emit({"phase": "converting"})
    try:
        convert_to_4bit(snapshot, destination)
    except Exception as error:  # noqa: BLE001
        log(f"convert failed: {error!r}")
        return fail(f"Couldn't convert this model to 4-bit: {error}")
    freed = delete_from_cache(repo_id)
    out.emit({"phase": "done", "id": converted_id(destination), "path": str(destination), "freed_bytes": freed})
    return 0


# ---------------------------------------------------------------- list / delete


def describe_folder(model_id: str, folder: Path, source: str, size: int) -> dict:
    config = read_json(folder / "config.json")
    model_type = config.get("model_type") if isinstance(config.get("model_type"), str) else None
    has_weights = any(folder.glob(WEIGHTS_PATTERN))
    return {
        "id": model_id,
        "name": display_name(model_id),
        "path": str(folder),
        "source": source,
        "bytes": size,
        "model_type": model_type,
        "supported": has_weights and architecture_supported(config) and not config.get("model_file"),
        "complete": is_complete(folder),
        "chat_template": folder_has_chat_template(folder),
    }


def installed_models() -> list[dict]:
    models: list[dict] = []
    try:
        repos = [repo for repo in scan_cache_dir(hub_cache()).repos if repo.repo_type == "model"]
    except CacheNotFound:
        repos = []
    for repo in repos:
        if not repo.revisions:
            continue
        revision = next(
            (rev for rev in repo.revisions if "main" in rev.refs),
            max(repo.revisions, key=lambda rev: rev.last_modified),
        )
        if (revision.snapshot_path / "config.json").is_file():
            models.append(describe_folder(repo.repo_id, revision.snapshot_path, "huggingface", repo.size_on_disk))
    root = converted_root()
    if root.is_dir():
        for folder in root.iterdir():
            if folder.is_dir() and not folder.name.endswith(".partial") and (folder / "config.json").is_file():
                models.append(describe_folder(converted_id(folder), folder, "converted", disk_size(folder)))
    return sorted(models, key=lambda model: (model["name"].casefold(), model["id"]))


def cmd_list(out: Output) -> int:
    try:
        out.emit({"models": installed_models()})
    except Exception as error:  # noqa: BLE001
        log(f"list failed: {error!r}")
        out.emit({"models": [], "error": str(error)})
        return 1
    return 0


def delete_folder(folder: Path) -> int:
    freed = disk_size(folder)
    shutil.rmtree(folder)
    return freed


def delete_target(raw: str) -> int:
    """Deletes a cached repo or converted folder given its id or any path inside it; returns bytes freed."""
    if is_path_argument(raw):
        path = Path(raw).expanduser().resolve()
        for root, kind in ((converted_root().resolve(), "converted"), (hub_cache().resolve(), "cache")):
            if path != root and path.is_relative_to(root):
                top = root / path.relative_to(root).parts[0]
                if kind == "converted":
                    return delete_folder(top)
                if not top.name.startswith("models--"):
                    raise ValueError("That isn't a model in the Hugging Face cache.")
                org, _, name = top.name.removeprefix("models--").partition("--")
                return delete_from_cache(f"{org}/{name}")
        raise ValueError("Refusing to delete a folder outside the Hugging Face cache and Local Grammar's models folder.")

    repo_id = normalize_id(raw)
    if repo_id is None:
        raise ValueError("That doesn't look like a model id (org/name) or path.")
    if cache_repo_dir(repo_id).is_dir():
        return delete_from_cache(repo_id)
    org, name = repo_id.split("/")
    folder = converted_root() / f"{org}--{name}"
    if folder.is_dir():
        return delete_folder(folder)
    raise ValueError("That model isn't installed.")


def cmd_delete(out: Output, raw: str) -> int:
    try:
        freed = delete_target(raw)
    except Exception as error:  # noqa: BLE001
        out.emit({"ok": False, "message": str(error)})
        return 1
    out.emit({"ok": True, "freed_bytes": freed})
    return 0


# ---------------------------------------------------------------- test / disk


def resolve_local(raw: str) -> Path:
    if is_path_argument(raw):
        folder = Path(raw).expanduser().resolve()
        if not (folder / "config.json").is_file():
            raise ValueError("That folder doesn't contain a model (no config.json).")
        return folder
    repo_id = normalize_id(raw)
    if repo_id is None:
        raise ValueError("That doesn't look like a model id (org/name) or path.")
    if (path := installed_path(repo_id)) is None:
        raise ValueError("That model isn't downloaded yet.")
    return path


def try_correct(corrector: Any, text: str) -> tuple[str, str | None]:
    """The correction, or the untouched text plus the reason when the model can't produce a usable answer."""
    try:
        return corrector.correct(text), None
    except Exception as error:  # noqa: BLE001 — one bad answer shouldn't sink the whole test
        return text, str(error) or type(error).__name__


def cmd_test(out: Output, raw: str) -> int:
    try:
        path = resolve_local(raw)
        from benchmark import CASES
        from corrector import Corrector

        start = time.perf_counter()
        corrector = Corrector(str(path))
        load_ms = round((time.perf_counter() - start) * 1000)
        try_correct(corrector, "warm up the model")
        examples = []
        elapsed = 0.0
        for text, expected in CASES:
            start = time.perf_counter()
            output, failure = try_correct(corrector, text)
            elapsed += time.perf_counter() - start
            example = {"input": text, "output": output, "expected": expected, "ok": None}
            if expected is not None:
                example["ok"] = failure is None and output == expected
            if failure is not None:
                example["error"] = failure
            examples.append(example)
    except Exception as error:  # noqa: BLE001
        log(f"test failed: {error!r}")
        out.emit({"error": str(error) or type(error).__name__})
        return 1
    scored = [example for example in examples if example["ok"] is not None]
    out.emit({
        "score": sum(example["ok"] for example in scored),
        "total": len(scored),
        "avg_ms": round(elapsed / len(CASES) * 1000),
        "load_ms": load_ms,
        "examples": examples,
    })
    return 0


def ram_bytes() -> int:
    try:
        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    except (ValueError, OSError):
        return 0


def cmd_disk(out: Output) -> int:
    usage = shutil.disk_usage(existing_ancestor(hub_cache()))
    out.emit({"free_bytes": usage.free, "total_bytes": usage.total, "ram_bytes": ram_bytes()})
    return 0


# ---------------------------------------------------------------- main


def quiet_libraries() -> None:
    for key, value in {
        "HF_HUB_DISABLE_PROGRESS_BARS": "1",
        "HF_HUB_DISABLE_TELEMETRY": "1",
        "TQDM_DISABLE": "1",
        "TRANSFORMERS_VERBOSITY": "error",
        "TRANSFORMERS_NO_ADVISORY_WARNINGS": "1",
        "TOKENIZERS_PARALLELISM": "false",
    }.items():
        os.environ.setdefault(key, value)
    disable_progress_bars()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("inspect").add_argument("model")
    download = commands.add_parser("download")
    download.add_argument("model")
    download.add_argument("--convert", action="store_true")
    commands.add_parser("list")
    commands.add_parser("delete").add_argument("model")
    commands.add_parser("test").add_argument("model")
    commands.add_parser("disk")
    args = parser.parse_args(argv)

    quiet_libraries()
    out = Output()
    try:
        match args.command:
            case "inspect":
                return cmd_inspect(out, args.model)
            case "download":
                return cmd_download(out, args.model, args.convert)
            case "list":
                return cmd_list(out)
            case "delete":
                return cmd_delete(out, args.model)
            case "test":
                return cmd_test(out, args.model)
            case "disk":
                return cmd_disk(out)
    except Exception as error:  # noqa: BLE001 — last resort, so the app always gets JSON it can show
        log(f"{args.command} failed: {error!r}")
        message = f"Something went wrong: {error}"
        out.emit({
            "inspect": empty_report(getattr(args, "model", ""), message),
            "download": {"phase": "error", "message": message},
            "delete": {"ok": False, "message": message},
        }.get(args.command, {"error": message}))
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
