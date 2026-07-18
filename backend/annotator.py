"""Gemini visual annotation for Nimbus OBJECTIVE action dicts.

annotate_steps() makes ONE Gemini Flash call to locate all visual targets
in the current drone frame, then merges box_2d/found/distance_m/confidence
back into each action dict.

Visual ops (ops that get Gemini annotation):
  fly_to   — only when the first arg is a named target, NOT a direction word
  orbit    — always has a target
  look_at  — always has a target
  follow   — always has a target

All other steps (and relative fly_to moves) pass through with:
  found=False, box_2d=[], confidence=0.0, distance_m=None
"""

from __future__ import annotations

import asyncio
import logging
import os
from pathlib import Path
from typing import Any

from dotenv import load_dotenv
from google import genai
from google.genai import types
from pydantic import BaseModel

from grounding import preprocess_image

load_dotenv(Path(__file__).resolve().parent / ".env")

logger = logging.getLogger(__name__)

_TARGET_OPS = frozenset({"fly_to", "orbit", "look_at", "follow"})
_RELATIVE_DIRECTIONS = frozenset({"forward", "back", "backward", "left", "right"})


# ---------------------------------------------------------------------------
# Pydantic schemas for the Gemini structured response
# ---------------------------------------------------------------------------

class TargetAnnotation(BaseModel):
    target: str
    found: bool
    box_2d: list[int]
    distance_m: float | None
    confidence: float


class AnnotationResult(BaseModel):
    annotations: list[TargetAnnotation]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _is_visual_step(action: dict[str, Any]) -> bool:
    """True if this step should receive a Gemini box annotation."""
    op = action.get("op", "")
    if op not in _TARGET_OPS:
        return False
    target = action.get("target")
    if not isinstance(target, str) or not target.strip():
        return False
    # fly_to with a direction word is a relative move — no visual target
    if target.lower() in _RELATIVE_DIRECTIONS:
        return False
    return True


def _empty_annotation() -> dict[str, Any]:
    return {"box_2d": [], "found": False, "distance_m": None, "confidence": 0.0}


def _call_gemini(api_key: str, image_bytes: bytes, targets: list[str]) -> AnnotationResult:
    """Synchronous Gemini call — run via asyncio.to_thread."""
    prompt = (
        "You are looking at a drone camera frame.\n"
        "For each target listed below, determine whether it is visible in the image.\n"
        "Return a JSON object with an 'annotations' array containing one entry per target.\n"
        "Fields per entry:\n"
        "  target    — copy the target string exactly as given\n"
        "  found     — true if visible, false otherwise\n"
        "  box_2d    — [ymin, xmin, ymax, xmax] normalized 0-1000 if found, else []\n"
        "  distance_m — estimated distance in meters if found (null if unknown or not found)\n"
        "  confidence — detection confidence 0.0-1.0\n\n"
        "Targets:\n" + "\n".join(f"- {t}" for t in targets)
    )
    try:
        processed = preprocess_image(image_bytes)
    except ValueError as exc:
        logger.warning("annotator: image preprocess failed: %s", exc)
        # Return not-found for all targets
        return AnnotationResult(
            annotations=[
                TargetAnnotation(
                    target=t, found=False, box_2d=[], distance_m=None, confidence=0.0
                )
                for t in targets
            ]
        )

    client = genai.Client(api_key=api_key)
    response = client.models.generate_content(
        model="gemini-flash-latest",
        contents=[
            types.Part.from_bytes(data=processed, mime_type="image/jpeg"),
            prompt,
        ],
        config=types.GenerateContentConfig(
            response_mime_type="application/json",
            response_schema=AnnotationResult,
        ),
    )
    return AnnotationResult.model_validate_json(response.text)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

async def annotate_steps(actions: list[dict], image_bytes: bytes) -> list[dict]:
    """Add visual grounding fields to each action dict.

    Identifies visual steps, makes ONE Gemini Flash call for all unique
    targets, and merges results back. Falls back gracefully if Gemini fails.

    Every action dict in the returned list has these keys added:
      box_2d      list[int]   [ymin, xmin, ymax, xmax] 0-1000, or []
      found       bool
      distance_m  float | None
      confidence  float
    """
    # Start with copies; seed every step with empty annotation
    result_actions: list[dict[str, Any]] = [dict(a) for a in actions]
    for action in result_actions:
        action.update(_empty_annotation())

    # Collect unique visual targets
    visual_indices: list[int] = []
    targets: list[str] = []
    seen: set[str] = set()

    for i, action in enumerate(result_actions):
        if _is_visual_step(action):
            visual_indices.append(i)
            t = action["target"].strip()
            if t.lower() not in seen:
                targets.append(t)
                seen.add(t.lower())

    if not targets:
        return result_actions

    api_key = os.environ.get("GEMINI_API_KEY", "").strip()
    if not api_key:
        logger.warning("GEMINI_API_KEY not set — skipping visual annotation")
        return result_actions

    try:
        ann_result = await asyncio.to_thread(
            _call_gemini, api_key, image_bytes, targets
        )
    except Exception as exc:
        logger.error(
            "Gemini annotation failed: %s — returning empty annotations for all visual steps",
            exc,
        )
        return result_actions

    # Build lookup by target name (case-insensitive)
    lookup: dict[str, TargetAnnotation] = {
        a.target.lower(): a for a in ann_result.annotations
    }

    # Merge annotations back into visual steps
    for i in visual_indices:
        target = result_actions[i]["target"].strip()
        ann = lookup.get(target.lower())
        if ann is None:
            logger.warning("No annotation returned for target %r", target)
            continue
        result_actions[i]["found"] = ann.found
        result_actions[i]["box_2d"] = ann.box_2d if ann.found else []
        result_actions[i]["distance_m"] = ann.distance_m if ann.found else None
        result_actions[i]["confidence"] = ann.confidence

    return result_actions
