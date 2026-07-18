<<<<<<< HEAD
#!/usr/bin/env python3
"""Call a deployed FreeSolo adapter: transcript in → OBJECTIVE JSON out.

  set FREESOLO_API_KEY=...
  set FREESOLO_BASE_URL=https://.../v1    # from: flash deployments --json
  set FREESOLO_MODEL=<run-id>
  python scripts/infer.py "take a picture of the red tent"
  python scripts/infer.py --repl
python3 scripts/infer.py --repl
"""

=======
>>>>>>> 5fcfe6f535d9a202aba7b8cace6455a0c5477e2b
from __future__ import annotations
import argparse
import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from objective import SYSTEM_PROMPT, parse_and_normalize  # noqa: E402

_CLIENT = None


def load_dotenv() -> None:
    env_path = ROOT / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        key, val = key.strip(), val.strip().strip('"').strip("'")
        if key.startswith("flash ") or " " in key:
            continue
        os.environ.setdefault(key, val)


def get_client():
    global _CLIENT
    if _CLIENT is not None:
        return _CLIENT
    try:
        from openai import OpenAI
    except ImportError as e:
        raise SystemExit("pip install openai") from e

    base_url = os.environ.get("FREESOLO_BASE_URL", "").rstrip("/")
    api_key = os.environ.get("FREESOLO_API_KEY", "")
    if not base_url or not api_key:
        raise SystemExit("Set FREESOLO_BASE_URL and FREESOLO_API_KEY in .env")
    _CLIENT = OpenAI(base_url=base_url, api_key=api_key, timeout=30.0)
    return _CLIENT


def infer(text: str) -> str:
    model = os.environ.get("FREESOLO_MODEL", "")
    if not model:
        raise SystemExit("Set FREESOLO_MODEL in .env")
    client = get_client()
    resp = client.chat.completions.create(
        model=model,
        temperature=0.0,
        max_tokens=512,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": text},
        ],
        response_format={"type": "json_object"},
    )
    return resp.choices[0].message.content or ""


def show(text: str) -> None:
    t0 = time.perf_counter()
    raw = infer(text)
    ms = (time.perf_counter() - t0) * 1000
    obj = parse_and_normalize(raw)
    print(raw)
    print(f"parsed ({ms:.0f} ms):", json.dumps(obj, indent=2) if obj else None)
    if obj is None:
        raise SystemExit(1)


def main() -> None:
    load_dotenv()
    parser = argparse.ArgumentParser()
    parser.add_argument("text", nargs="?", help="Transcript to convert")
    parser.add_argument("--repl", action="store_true")
    args = parser.parse_args()

    if args.repl:
        # Warm connection once
        get_client()
        print("OBJECTIVE REPL — empty line to quit")
        while True:
            try:
                line = input("> ").strip()
            except (EOFError, KeyboardInterrupt):
                print()
                break
            if not line:
                break
            try:
                show(line)
            except SystemExit:
                print("parse failed", file=sys.stderr)
        return

    if not args.text:
        parser.error("pass a transcript or --repl")
    show(args.text)


if __name__ == "__main__":
    main()
