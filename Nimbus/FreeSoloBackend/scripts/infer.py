#!/usr/bin/env python3
"""Call a deployed FreeSolo adapter: transcript in → OBJECTIVE JSON out.

  set FREESOLO_API_KEY=...
  set FREESOLO_BASE_URL=https://.../v1    # from: flash deployments --json
  set FREESOLO_MODEL=<run-id>
  python scripts/infer.py "take a picture of the red tent"
  python scripts/infer.py --repl
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from objective import SYSTEM_PROMPT, parse_and_normalize  # noqa: E402


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


def infer(text: str) -> str:
    try:
        from openai import OpenAI
    except ImportError as e:
        raise SystemExit("pip install openai") from e

    base_url = os.environ.get("FREESOLO_BASE_URL", "").rstrip("/")
    api_key = os.environ.get("FREESOLO_API_KEY", "")
    model = os.environ.get("FREESOLO_MODEL", "")
    if not base_url or not api_key or not model:
        raise SystemExit(
            "Set FREESOLO_BASE_URL, FREESOLO_API_KEY, and FREESOLO_MODEL "
            "(see flash deployments --json after deploy)."
        )

    client = OpenAI(base_url=base_url, api_key=api_key)
    resp = client.chat.completions.create(
        model=model,
        temperature=0.0,
        max_tokens=256,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": text},
        ],
        response_format={"type": "json_object"},
    )
    return resp.choices[0].message.content or ""


def main() -> None:
    load_dotenv()
    parser = argparse.ArgumentParser()
    parser.add_argument("text", nargs="?", help="Transcript to convert")
    parser.add_argument("--repl", action="store_true", help="Interactive loop")
    args = parser.parse_args()

    if args.repl:
        print("OBJECTIVE REPL — empty line to quit")
        while True:
            try:
                line = input("> ").strip()
            except (EOFError, KeyboardInterrupt):
                print()
                break
            if not line:
                break
            raw = infer(line)
            obj = parse_and_normalize(raw)
            print(raw)
            print("parsed:", json.dumps(obj, indent=2) if obj else None)
        return

    if not args.text:
        parser.error("pass a transcript or --repl")
    raw = infer(args.text)
    obj = parse_and_normalize(raw)
    print(raw)
    if obj is None:
        print("FAILED to parse OBJECTIVE", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(obj, indent=2))


if __name__ == "__main__":
    main()
