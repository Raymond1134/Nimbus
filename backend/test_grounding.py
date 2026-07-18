"""
Batch smoke-test for ground_target().

Loops over every image in backend/test_images/ and prints a results table.

TEST IMAGE GUIDE — add these files to backend/test_images/ manually:
  blurry_motion.jpg   — a motion-blurred or out-of-focus photo; tests robustness
                        against low image quality that a drone camera might produce.
  small_far_target.jpg — target object is tiny and far from the camera; confirms the
                         bounding box is still returned (or gracefully missed) at low
                         pixel coverage.
  no_target.jpg       — a scene that definitely does NOT contain the target object;
                        confirms found=False is returned rather than a hallucinated box.

Usage:
    python test_grounding.py
"""

import time
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

from grounding import ground_target  # noqa: E402 (import after load_dotenv)

_MIME_MAP = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
    ".gif": "image/gif",
}

# Map filename (stem or full name) → target_description used for that image.
# Files not listed here get the generic target "object".
TEST_CASES: dict[str, str] = {
    "red trash can.png": "red trash can",
    "low res can.png": "red trash can",
    "small red can.png": "red trash can",
    "no can.jpg": "red trash can",
}

_COL = {
    "file": 28,
    "target": 22,
    "found": 6,
    "conf": 10,
    "ms": 10,
}


def _row(*cells: str) -> str:
    keys = list(_COL)
    return "  ".join(str(c).ljust(_COL[k]) for k, c in zip(keys, cells))


def main() -> None:
    test_images_dir = Path(__file__).parent / "test_images"
    candidates = sorted(
        p for p in test_images_dir.iterdir() if p.suffix.lower() in _MIME_MAP
    )

    if not candidates:
        print(f"No images found in {test_images_dir}.")
        print("Add images there and re-run.")
        return

    header = _row("Filename", "Target", "Found", "Confidence", "Latency(ms)")
    separator = "-" * len(header)
    print(f"\n{header}")
    print(separator)

    for path in candidates:
        target = TEST_CASES.get(path.name, "object")
        mime_type = _MIME_MAP.get(path.suffix.lower(), "image/jpeg")

        t0 = time.time()
        try:
            result = ground_target(path.read_bytes(), target, mime_type)
        except Exception as exc:
            elapsed_ms = (time.time() - t0) * 1000
            print(_row(path.name, target, "ERROR", "-", f"{elapsed_ms:.0f}"))
            print(f"    Exception: {exc}")
            continue

        elapsed_ms = (time.time() - t0) * 1000
        print(_row(
            path.name,
            target,
            str(result.found),
            f"{result.confidence:.2f}",
            f"{elapsed_ms:.0f}",
        ))

    print(separator)
    print()


if __name__ == "__main__":
    main()
