from __future__ import annotations
import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from objective import dumps_objective, make_objective  # noqa: E402

TRAIN = ROOT / "dataset" / "train.jsonl"

SEEDS = [
    ("land", [{"op": "land"}], 1.0),
    ("stop", [{"op": "abort"}], 1.0),
    ("come back", [{"op": "return"}], 0.95),
    ("take a picture", [{"op": "photo"}], 0.95),
    (
        "fly to the tree and take a picture then spin around and come back",
        [
            {"op": "fly_to", "target": "tree"},
            {"op": "photo"},
            {"op": "spin", "yaw_deg": 360.0},
            {"op": "return"},
        ],
        0.95,
    ),
    (
        "orbit the picnic table twice",
        [{"op": "orbit", "target": "picnic table", "revolutions": 2.0}],
        0.95,
    ),
    (
        "fly under the bridge then hover for 5 seconds",
        [{"op": "fly_under", "target": "bridge"}, {"op": "hover", "duration_s": 5.0}],
        0.95,
    ),
    (
        "follow the dog for 10 seconds",
        [{"op": "follow", "target": "dog", "duration_s": 10.0}],
        0.95,
    ),
    (
        "go forward 3 meters",
        [{"op": "fly_rel", "direction": "forward", "distance_m": 3.0}],
        0.95,
    ),
    ("just hover", [{"op": "hover_station"}], 0.95),
]


def as_msg_row(inp: str, objective_json: str) -> dict:
    return {
        "input": inp,
        "output": {"messages": [{"role": "assistant", "content": objective_json}]},
    }


def main() -> None:
    if not TRAIN.exists():
        raise SystemExit(f"missing {TRAIN}; run generate_dataset.py first")

    seeds: list[dict] = []
    for inp, actions, conf in SEEDS:
        obj = dumps_objective(make_objective(actions, conf))
        for _ in range(5):
            seeds.append(as_msg_row(inp, obj))

    # Handle corrupted single-line file (literal \n) or normal jsonl
    text = TRAIN.read_text(encoding="utf-8")
    if "\\n{" in text[:500] and text.count("\n") < 10:
        lines = [ln for ln in text.split("\\n") if ln.strip()]
    else:
        lines = [ln for ln in text.splitlines() if ln.strip()]

    raw: list[dict] = []
    for line in lines:
        r = json.loads(line)
        content = r["output"]
        if isinstance(content, dict) and "messages" in content:
            # unwrap to re-wrap cleanly
            msgs = content["messages"]
            content = msgs[-1]["content"] if msgs else ""
        raw.append(as_msg_row(r["input"], content))

    rng = random.Random(42)
    rng.shuffle(raw)
    seed_inputs = {r["input"] for r in seeds}
    merged = seeds + [r for r in raw if r["input"] not in seed_inputs]

    with TRAIN.open("w", encoding="utf-8", newline="\n") as f:
        for r in merged[:20000]:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"wrote {min(20000, len(merged))} rows to {TRAIN}")


if __name__ == "__main__":
    main()
