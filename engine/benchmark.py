import sys
import time

from corrector import Corrector

CASES = [
    ("He go to the markt yesterday and buyed two apple.", "He went to the market yesterday and bought two apples."),
    ("Their is a dog in the garden and it look very happy.", "There is a dog in the garden and it looks very happy."),
    ("I has a idea for the project, lets discuss it tommorow.", "I have an idea for the project, let's discuss it tomorrow."),
    ("can you send me the report by eod, i need to review it before the meeting", None),
    ("The datas shows that our revenue have increased since last quarter.", "The data shows that our revenue has increased since last quarter."),
    ("Please review the PR and let me know if anything needs changing.", "Please review the PR and let me know if anything needs changing."),
    ("What is the capital of France?", "What is the capital of France?"),
    (
        "Hi team,\n\nI wanted to give a quick update on the migration. We has finished the backend part, "
        "but the frontend still need some work. I think we can finish it by friday if every thing go well.\n\nThanks,\nSamir",
        None,
    ),
]


def run(model_id: str):
    load_start = time.perf_counter()
    corrector = Corrector(model_id)
    print(f"\n### {model_id}  (load {time.perf_counter() - load_start:.1f}s)")
    corrector.correct("warm up the model")
    total = 0.0
    exact = 0
    scored = 0
    for text, expected in CASES:
        start = time.perf_counter()
        result = corrector.correct(text)
        elapsed = time.perf_counter() - start
        total += elapsed
        verdict = ""
        if expected is not None:
            scored += 1
            exact += result == expected
            verdict = "OK " if result == expected else "-- "
        print(f"  [{elapsed * 1000:5.0f} ms] {verdict}{result!r}")
    print(f"  => exact {exact}/{scored}, avg {total / len(CASES) * 1000:.0f} ms")


if __name__ == "__main__":
    for model_id in sys.argv[1:]:
        run(model_id)
