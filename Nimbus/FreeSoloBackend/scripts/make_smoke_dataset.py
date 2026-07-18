#!/usr/bin/env python3
"""Tiny gold smoke dataset using flat steps[] strings."""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from objective import dumps_objective, make_objective  # noqa: E402

EXAMPLES = [
    ("land", ["land"]),
    ("stop", ["abort"]),
    ("come back", ["return"]),
    ("take a picture", ["photo"]),
    ("just hover", ["hover_station"]),
    ("fly to the tree", ["fly_to|tree"]),
    ("fly to the red tent and take a picture", ["fly_to|red tent", "photo"]),
    (
        "fly to that tree, take a picture, then spin around and come back",
        ["fly_to|tree", "photo", "spin|360", "return"],
    ),
    ("orbit the picnic table twice", ["orbit|picnic table|2"]),
    ("fly under the bridge then hover for 5 seconds", ["fly_under|bridge", "hover|5"]),
    ("go forward 3 meters", ["fly_rel|forward|3"]),
    ("follow the dog for 10 seconds", ["follow|dog|10"]),
    ("spin around", ["spin|360"]),
    ("hello", ["say|Ready. Say a flight command."]),
]


def main() -> None:
    path = ROOT / "dataset" / "smoke.jsonl"
    rows = []
    for inp, steps in EXAMPLES:
        out = dumps_objective(make_objective(steps, 0.95))
        for _ in range(8):
            rows.append({"input": inp, "output": out})
    with path.open("w", encoding="utf-8", newline="\n") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"wrote {len(rows)} rows -> {path}")
    print("sample:", rows[7]["output"])


if __name__ == "__main__":
    main()
