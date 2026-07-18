#!/usr/bin/env python3
"""Call the deployed FreeSolo adapter: transcript in -> OBJECTIVE JSON out.

Env (in FreeSoloBackend/.env or shell):
  FREESOLO_API_KEY=...
  FREESOLO_BASE_URL=https://.../v1     # from: flash deployments --json
  FREESOLO_MODEL=<run-id>

Usage:
  python scripts/infer.py "take a picture of the red tent"
  python scripts/infer.py --repl
  python scripts/infer.py --eval dataset/eval.jsonl --limit 50

The LAST line printed is always the normalized objective JSON
({"steps": [...], "actions": [...], "confidence": ...}) so callers
(server.py) can parse stdout's final line.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from objective import SYSTEM_PROMPT, parse_and_normalize, score_objectives  # noqa: E402

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
        if " " in key:
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
        max_tokens=256,
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
    print(f"raw ({ms:.0f} ms): {raw}", file=sys.stderr)
    if obj is None:
        print("null")
        raise SystemExit(1)
    print(json.dumps(obj, ensure_ascii=False))


def run_eval(path: Path, limit: int) -> None:
    rows = [json.loads(l) for l in path.read_text(encoding="utf-8").splitlines() if l.strip()]
    rows = rows[:limit]
    total, parsed_ok = 0.0, 0
    for i, r in enumerate(rows):
        raw = infer(r["input"])
        pred = parse_and_normalize(raw)
        exp = parse_and_normalize(r["output"])
        s = score_objectives(pred, exp)
        total += s
        parsed_ok += pred is not None
        flag = "OK " if s >= 0.99 else ("~  " if s >= 0.5 else "BAD")
        print(f"[{i:03d}] {flag} score={s:.2f} in={r['input']!r}", file=sys.stderr)
        if s < 0.99:
            print(f"      pred={pred and pred['steps']}", file=sys.stderr)
            print(f"      gold={exp and exp['steps']}", file=sys.stderr)
    n = max(1, len(rows))
    print(
        json.dumps(
            {"n": len(rows), "mean_score": round(total / n, 4), "parse_rate": round(parsed_ok / n, 4)}
        )
    )


def main() -> None:
    load_dotenv()
    parser = argparse.ArgumentParser()
    parser.add_argument("text", nargs="?", help="Transcript to convert")
    parser.add_argument("--repl", action="store_true")
    parser.add_argument("--eval", dest="eval_path", help="JSONL file with input/output rows")
    parser.add_argument("--limit", type=int, default=50)
    args = parser.parse_args()

    if args.eval_path:
        run_eval(Path(args.eval_path), args.limit)
        return

    if args.repl:
        get_client()
        print("OBJECTIVE REPL — empty line to quit", file=sys.stderr)
        while True:
            try:
                line = input("> ").strip()
            except (EOFError, KeyboardInterrupt):
                break
            if not line:
                break
            try:
                show(line)
            except SystemExit:
                print("parse failed", file=sys.stderr)
        return

    if not args.text:
        parser.error("pass a transcript, --repl, or --eval")
    show(args.text)


if __name__ == "__main__":
    main()
