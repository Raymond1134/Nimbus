"""
Quick smoke-test for ground_target().

Usage:
    python test_grounding.py                         # picks first image in test_images/
    python test_grounding.py path/to/image.jpg       # explicit image, default target "object"
    python test_grounding.py path/to/image.jpg "red trash can"  # explicit image + target
"""

import sys
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


def main() -> None:
    if len(sys.argv) > 1:
        image_path = Path(sys.argv[1])
    else:
        test_images_dir = Path(__file__).parent / "test_images"
        candidates = [
            p for p in test_images_dir.iterdir()
            if p.suffix.lower() in _MIME_MAP
        ]
        if not candidates:
            print(
                f"No images found in {test_images_dir}.\n"
                "Add an image there or pass a path as the first argument."
            )
            sys.exit(1)
        image_path = candidates[0]

    target = sys.argv[2] if len(sys.argv) > 2 else "object"
    mime_type = _MIME_MAP.get(image_path.suffix.lower(), "image/jpeg")

    print(f"Image:     {image_path}")
    print(f"Target:    {target}")
    print(f"MIME type: {mime_type}")
    print()

    result = ground_target(image_path.read_bytes(), target, mime_type)
    print(result.model_dump_json(indent=2))


if __name__ == "__main__":
    main()
