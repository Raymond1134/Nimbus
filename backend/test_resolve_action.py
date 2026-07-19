"""Smoke tests for resolve_action().

Calls resolve_action() directly (no HTTP server required) against real images
in backend/test_images/ and pretty-prints the full ActionResolution for each
case. Results are for manual inspection only — there are no assertions.

Usage:
    cd backend
    python test_resolve_action.py

Requires GEMINI_API_KEY to be set in backend/.env (or the environment).

Test cases:
  1. seek_object   — target is a physical object visible in the frame
  2. fly_direction — target is a lateral direction word
  3. change_altitude — target implies vertical movement
"""

import json
import logging
import sys
from pathlib import Path

# Make sure imports resolve when run from the backend/ directory
sys.path.insert(0, str(Path(__file__).resolve().parent))

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent / ".env")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)

from resolve_action import resolve_action  # noqa: E402 — must come after path + dotenv setup

_IMAGES = Path(__file__).resolve().parent / "test_images"

CASES = [
    {
        "name": "seek_object — red trash can",
        "image_path": _IMAGES / "redtrashcan.png",
        "raw_target": "red trash can",
        "raw_intent": "seek_and_photo",
        "expected_type_hint": "seek_object",
    },
    {
        "name": "fly_direction — left",
        "image_path": _IMAGES / "no can.jpg",
        "raw_target": "left",
        "raw_intent": "fly_direction",
        "expected_type_hint": "fly_direction",
    },
    {
        "name": "change_altitude — up higher",
        "image_path": _IMAGES / "no can.jpg",
        "raw_target": "up higher",
        "raw_intent": "change_altitude",
        "expected_type_hint": "change_altitude",
    },
]


def run_tests() -> None:
    passed = 0
    failed = 0

    for i, case in enumerate(CASES, start=1):
        print(f"\n{'='*60}")
        print(f"Test {i}: {case['name']}")
        print(f"  image      : {case['image_path'].name}")
        print(f"  raw_target : {case['raw_target']!r}")
        print(f"  raw_intent : {case['raw_intent']!r}")
        print(f"  expected   : {case['expected_type_hint']}")
        print("-" * 60)

        image_path = case["image_path"]
        if not image_path.exists():
            print(f"  ERROR: image not found at {image_path}")
            failed += 1
            continue

        image_bytes = image_path.read_bytes()

        result = resolve_action(image_bytes, case["raw_target"], case["raw_intent"])
        result_dict = result.model_dump()

        print("  ActionResolution:")
        print(json.dumps(result_dict, indent=4))

        actual = result.action_type
        hint = case["expected_type_hint"]
        if actual == hint:
            print(f"  CLASSIFICATION MATCH: got '{actual}' (expected '{hint}')")
            passed += 1
        else:
            print(f"  CLASSIFICATION MISMATCH: got '{actual}', expected '{hint}'")
            failed += 1

    print(f"\n{'='*60}")
    print(f"Results: {passed} matched / {failed} mismatched out of {len(CASES)} tests")
    print("(These are smoke tests for manual review — no strict pass/fail criteria.)")


if __name__ == "__main__":
    run_tests()
