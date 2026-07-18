#!/usr/bin/env python3
"""End-to-end: transcript → FreeSolo OBJECTIVE → MissionPlan (Gemini or fallback).

Usage:
  cd backend
  python e2e_pipeline.py "fly to the tree, take a picture, then come back"
  python e2e_pipeline.py "orbit the picnic table twice" --image path/to.jpg

Requires FreeSoloBackend/.env (or backend/.env) with FREESOLO_* set.
GEMINI_API_KEY optional — without it, uses deterministic expand fallback.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent
FS_ROOT = ROOT.parent / "Nimbus" / "FreeSoloBackend"

# Prefer backend/.env, also pull FreeSoloBackend/.env for shared keys
load_dotenv(ROOT / ".env")
load_dotenv(FS_ROOT / ".env")

sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(FS_ROOT))

from objective import SYSTEM_PROMPT, parse_and_normalize  # noqa: E402
from planner import expand_objective_skeleton, plan_mission  # noqa: E402


def _tiny_jpeg() -> bytes:
    """Minimal valid JPEG (1x1) so plan_mission can run without a real frame."""
    try:
        from PIL import Image
        import io

        buf = io.BytesIO()
        Image.new("RGB", (64, 64), color=(120, 160, 200)).save(buf, format="JPEG")
        return buf.getvalue()
    except ImportError:
        # Prebuilt tiny JPEG
        return bytes.fromhex(
            "ffd8ffe000104a46494600010100000100010000ffdb004300080606070605080707"
            "070909080a0c140d0c0b0b0c1912130f141d1a1f1e1d1a1c1c20242e2720222c231c"
            "1c2837292c30313434341f27393d38323c2e333432ffdb0043010909090c0b0c180d"
            "0d1832211c2132323232323232323232323232323232323232323232323232323232"
            "323232323232323232323232323232323232323232ffc00011080001000103011100"
            "02110311ffc40014000100000000000000000000000000000008ffc4001410010000"
            "0000000000000000000000000000ffda000c0301000210031000003f00bf80ffd9"
        )


def call_freesolo(transcript: str) -> dict:
    from openai import OpenAI

    base = os.environ.get("FREESOLO_BASE_URL", "").rstrip("/")
    key = os.environ.get("FREESOLO_API_KEY", "")
    model = os.environ.get("FREESOLO_MODEL", "")
    if not (base and key and model):
        raise SystemExit("Set FREESOLO_BASE_URL, FREESOLO_API_KEY, FREESOLO_MODEL in .env")

    client = OpenAI(base_url=base, api_key=key, timeout=30.0)
    t0 = time.perf_counter()
    resp = client.chat.completions.create(
        model=model,
        temperature=0.0,
        max_tokens=256,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": transcript},
        ],
        response_format={"type": "json_object"},
    )
    ms = (time.perf_counter() - t0) * 1000
    raw = resp.choices[0].message.content or ""
    obj = parse_and_normalize(raw, lenient=True)
    print(f"[FreeSolo] {ms:.0f} ms raw={raw}")
    if obj is None:
        raise SystemExit(f"FreeSolo returned unparseable OBJECTIVE: {raw!r}")
    return obj


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("transcript", help="Spoken command text")
    ap.add_argument("--image", help="Optional JPEG/PNG path for Gemini grounding")
    ap.add_argument(
        "--skeleton-only",
        action="store_true",
        help="Skip Gemini/grounding; only expand OBJECTIVE → InstructionSteps",
    )
    args = ap.parse_args()

    objective = call_freesolo(args.transcript)
    print("[OBJECTIVE]", json.dumps(objective, indent=2))

    if args.skeleton_only:
        steps = expand_objective_skeleton(objective)
        plan = {
            "steps": [s.model_dump() for s in steps],
            "planner": "skeleton",
            "confidence": objective.get("confidence"),
        }
    else:
        if args.image:
            image_bytes = Path(args.image).read_bytes()
        else:
            image_bytes = _tiny_jpeg()
        t0 = time.perf_counter()
        mission = plan_mission(objective, image_bytes)
        ms = (time.perf_counter() - t0) * 1000
        print(f"[Planner] {ms:.0f} ms planner={mission.planner} blocked={mission.blocked}")
        plan = mission.model_dump()

    print("[PLAN]", json.dumps(plan, indent=2))
    gemini = bool(os.environ.get("GEMINI_API_KEY", "").strip())
    print(
        json.dumps(
            {
                "ok": True,
                "freesolo_model": os.environ.get("FREESOLO_MODEL"),
                "gemini_enabled": gemini,
                "steps": len(plan.get("steps") or []),
            }
        )
    )


if __name__ == "__main__":
    main()
