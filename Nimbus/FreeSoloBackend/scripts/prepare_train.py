#!/usr/bin/env python3
"""Prepend gold seeds to train.jsonl (scalar output — matches working v1 SFT style)."""

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


def row(inp: str, actions: list, conf: float) -> dict:
    return {
        "input": inp,
        "output": dumps_objective(make_objective(actions, conf)),
    }


def main() -> None:
    seeds: list[dict] = []
    for inp, actions, conf in SEEDS:
        for _ in range(8):
            seeds.append(row(inp, actions, conf))

    raw: list[dict] = []
    for line in TRAIN.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        r = json.loads(line)
        content = r["output"]
        if isinstance(content, dict) and "messages" in content:
            content = content["messages"][-1]["content"]
        raw.append({"input": r["input"], "output": content})

    rng = random.Random(42)
    rng.shuffle(raw)
    seed_inputs = {r["input"] for r in seeds}
    merged = seeds + [r for r in raw if r["input"] not in seed_inputs]

    with TRAIN.open("w", encoding="utf-8", newline="\n") as f:
        for r in merged[:20000]:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"wrote {min(20000, len(merged))} scalar rows (seeds={len(seeds)})")


if __name__ == "__main__":
    main()
