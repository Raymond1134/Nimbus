"""
Eyeball test for POST /voice_command in mock mode.

Runs entirely in-process via FastAPI's TestClient — no server, no external
endpoints needed.  Make sure USE_FREESOLO_MOCK=true in .env (it is by
default) before running.

Usage (from the backend/ directory):
    python test_voice_command.py
"""

import io
import json
import os
import sys
import warnings
from pathlib import Path

# Suppress the starlette TestClient/httpx version warning — cosmetic only.
warnings.filterwarnings("ignore", category=DeprecationWarning, module="starlette")

# Ensure .env is loaded before importing main (which reads env at import time).
from dotenv import load_dotenv

load_dotenv()

# Force mock mode for this script regardless of whatever .env says, so the
# test is always self-contained.
os.environ["USE_FREESOLO_MOCK"] = "true"

from fastapi.testclient import TestClient  # noqa: E402

from main import app  # noqa: E402

client = TestClient(app)

_TEST_IMAGES_DIR = Path(__file__).parent / "test_images"

# Each entry: (transcript, image_filename)
# image_filename is relative to test_images/; use None to generate a synthetic image.
TEST_CASES: list[tuple[str, str | None]] = [
    ("fly to the red trash can",          "red trash can.png"),
    ("find the pillar and photograph it", "low res can.png"),
    ("locate the green box near the wall","small red can.png"),
    ("go towards that building",          "no can.jpg"),
    ("take a photo of the blue door",     None),   # synthetic image — tests extraction only
]

_EXPECTED_KEYS = {
    "intent", "target", "say_text", "constraints", "confidence",
    "found", "box_2d", "label", "grounding_confidence",
}

_COL_TRANSCRIPT = 42
_COL_TARGET     = 22
_COL_FOUND      = 7
_COL_GCONF      = 10
_COL_STATUS     = 6


def _synthetic_jpeg() -> bytes:
    """Return a tiny valid JPEG (1×1 white pixel) as a fallback image."""
    try:
        from PIL import Image
        buf = io.BytesIO()
        Image.new("RGB", (1, 1), color=(255, 255, 255)).save(buf, format="JPEG")
        return buf.getvalue()
    except ImportError:
        # Raw 1×1 white JPEG bytes (pre-encoded, always valid).
        return (
            b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
            b"\xff\xdb\x00C\x00\x08\x06\x06\x07\x06\x05\x08\x07\x07\x07\t\t"
            b"\x08\n\x0c\x14\r\x0c\x0b\x0b\x0c\x19\x12\x13\x0f\x14\x1d\x1a"
            b"\x1f\x1e\x1d\x1a\x1c\x1c $.' \",#\x1c\x1c(7),01444\x1f'9=82<.342\x1e"
            b"\xff\xc0\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00"
            b"\xff\xc4\x00\x1f\x00\x00\x01\x05\x01\x01\x01\x01\x01\x01\x00\x00"
            b"\x00\x00\x00\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07\x08\t\n\x0b"
            b"\xff\xc4\x00\xb5\x10\x00\x02\x01\x03\x03\x02\x04\x03\x05\x05\x04"
            b"\x04\x00\x00\x01}\x01\x02\x03\x00\x04\x11\x05\x12!1A\x06\x13Qa"
            b"\x07\"q\x142\x81\x91\xa1\x08#B\xb1\xc1\x15R\xd1\xf0$3br\x82\t\n"
            b"\x16\x17\x18\x19\x1a%&'()*456789:CDEFGHIJSTUVWXYZ"
            b"cdefghijstuvwxyz\x83\x84\x85\x86\x87\x88\x89\x8a\x92\x93\x94\x95"
            b"\x96\x97\x98\x99\x9a\xa2\xa3\xa4\xa5\xa6\xa7\xa8\xa9\xaa\xb2\xb3"
            b"\xb4\xb5\xb6\xb7\xb8\xb9\xba\xc2\xc3\xc4\xc5\xc6\xc7\xc8\xc9\xca"
            b"\xd2\xd3\xd4\xd5\xd6\xd7\xd8\xd9\xda\xe1\xe2\xe3\xe4\xe5\xe6\xe7"
            b"\xe8\xe9\xea\xf1\xf2\xf3\xf4\xf5\xf6\xf7\xf8\xf9\xfa"
            b"\xff\xda\x00\x08\x01\x01\x00\x00?\x00\xfb\xd4P\x00\x00\x00\x1f\xff\xd9"
        )


def _load_image(filename: str | None) -> tuple[bytes, str, str]:
    """Return (image_bytes, content_type, source_label)."""
    if filename is None:
        return _synthetic_jpeg(), "image/jpeg", "<synthetic 1×1 JPEG>"

    path = _TEST_IMAGES_DIR / filename
    if not path.exists():
        return b"", "", ""  # caller checks for empty bytes → skip

    suffix = path.suffix.lower()
    mime = {
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".png": "image/png",
        ".webp": "image/webp",
    }.get(suffix, "image/jpeg")

    return path.read_bytes(), mime, filename


def _header(*cells: tuple[str, int]) -> str:
    return "  ".join(str(v).ljust(w) for v, w in cells)


def main() -> None:
    print("\n" + "=" * 90)
    print("  POST /voice_command  —  mock mode eyeball test")
    print("=" * 90)

    header = _header(
        ("Transcript", _COL_TRANSCRIPT),
        ("Extracted target", _COL_TARGET),
        ("Found", _COL_FOUND),
        ("GndConf", _COL_GCONF),
        ("Keys", _COL_STATUS),
    )
    sep = "-" * len(header)
    print(f"\n{header}")
    print(sep)

    all_passed = True

    for transcript, image_filename in TEST_CASES:
        image_bytes, content_type, source_label = _load_image(image_filename)

        if image_filename is not None and not image_bytes:
            print(
                _header(
                    (transcript[:_COL_TRANSCRIPT], _COL_TRANSCRIPT),
                    ("<skipped — image not found>", _COL_TARGET),
                    ("-", _COL_FOUND),
                    ("-", _COL_GCONF),
                    ("SKIP", _COL_STATUS),
                )
            )
            continue

        resp = client.post(
            "/voice_command",
            data={"transcript": transcript},
            files={"image": (source_label, io.BytesIO(image_bytes), content_type)},
        )

        if resp.status_code != 200:
            print(
                _header(
                    (transcript[:_COL_TRANSCRIPT], _COL_TRANSCRIPT),
                    (f"HTTP {resp.status_code}", _COL_TARGET),
                    ("-", _COL_FOUND),
                    ("-", _COL_GCONF),
                    ("FAIL", _COL_STATUS),
                )
            )
            print(f"    Response body: {resp.text[:200]}")
            all_passed = False
            continue

        body = resp.json()
        missing = _EXPECTED_KEYS - set(body.keys())
        keys_ok = "OK" if not missing else f"MISS:{','.join(sorted(missing))}"

        if missing:
            all_passed = False

        print(
            _header(
                (transcript[:_COL_TRANSCRIPT], _COL_TRANSCRIPT),
                (str(body.get("target", ""))[:_COL_TARGET], _COL_TARGET),
                (str(body.get("found", ""))[:_COL_FOUND], _COL_FOUND),
                (f"{body.get('grounding_confidence', 0.0):.2f}"[:_COL_GCONF], _COL_GCONF),
                (keys_ok[:_COL_STATUS], _COL_STATUS),
            )
        )

        # Full JSON dump for eyeballing.
        print(f"    {json.dumps(body, indent=None)}")

    print(sep)
    print(
        "\nAll key checks PASSED.\n"
        if all_passed
        else "\nSome checks FAILED — see rows above.\n"
    )

    if not all_passed:
        sys.exit(1)


if __name__ == "__main__":
    main()
