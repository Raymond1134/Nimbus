#!/usr/bin/env python3
"""Tiny gold smoke dataset covering every op once-plus (fast format check)."""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from objective import dumps_objective, make_objective  # noqa: E402

EXAMPLES = [
    # All valid ops represented
    ("take off", ["takeoff"]),
    ("land", ["land"]),
    ("stop", ["abort"]),
    ("come back", ["return"]),
    ("take a picture", ["photo"]),
    ("take a selfie", ["selfie"]),
    ("do a 360 panorama", ["panorama"]),
    ("just hover", ["hover"]),
    ("hover for 10 seconds", ["hover|10"]),
    ("fly to the tree", ["fly_to|tree"]),
    ("go up", ["change_altitude"]),
    ("fly up", ["change_altitude"]),              # critical: must NOT be fly_to|up
    ("fly up 2 meters", ["change_altitude|+2"]),   # critical: with value
    ("fly down", ["change_altitude|-0.5"]),
    ("go down 3 meters", ["change_altitude|-3"]),
    ("fly forward", ["fly_to|forward"]),
    ("move left 2 meters", ["fly_to|left|2"]),
    ("rotate left", ["rotate|left"]),
    ("turn right 90 degrees", ["rotate|right|90"]),
    ("spin around", ["rotate|right|360"]),
    ("look at the fountain", ["look_at|fountain"]),
    ("orbit the picnic table twice", ["orbit|picnic table|2"]),
    ("follow the dog for 10 seconds", ["follow|dog|10"]),
    ("hello", ["say|Ready. Say a flight command."]),
    # Compounds
    (
        "fly to the red tent, take a picture, then spin around and come back",
        ["fly_to|red tent", "photo", "rotate|right|360", "return"],
    ),
    # The exact failing case from v2
    ("move left a meter and then fly up", ["fly_to|left|1", "change_altitude"]),
    ("go right 2 meters then fly up 3 meters", ["fly_to|right|2", "change_altitude|+3"]),
]


def main() -> None:
    path = ROOT / "dataset" / "smoke.jsonl"
    rows = []
    for inp, steps in EXAMPLES:
        out = dumps_objective(make_objective(steps, 0.95))
        for _ in range(6):
            rows.append({"input": inp, "output": out})
    with path.open("w", encoding="utf-8", newline="\n") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"wrote {len(rows)} rows -> {path}")
    print("sample:", rows[0]["output"])


if __name__ == "__main__":
    main()
