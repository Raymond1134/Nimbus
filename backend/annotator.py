"""Gemini visual grounding for Nimbus OBJECTIVE action dicts.

FreeSolo v3 produces the full mission plan with ops already disambiguated:
  fly_to|<target>       — visual approach (needs resolve_action)
  fly_direction|left|N  — directional move (no Gemini needed)
  change_altitude|N — altitude change  (no Gemini needed)

For each visual step, resolve_action() is called with the target string
and op name. It returns box_2d (0-1000 normalized) + confidence.
Non-visual steps pass through with box_2d=[] / found=False.
"""

from __future__ import annotations

import asyncio
import logging
import os
from pathlib import Path
from typing import Any

from dotenv import load_dotenv
from resolve_action import resolve_action

load_dotenv(Path(__file__).resolve().parent / ".env")

logger = logging.getLogger(__name__)

# Ops that require Gemini visual grounding via resolve_action.
# follow has a target but is tracked autonomously — no box needed.
_TARGET_OPS = frozenset({"fly_to", "orbit", "look_at"})
_RELATIVE_DIRECTIONS = frozenset({"forward", "back", "backward", "left", "right"})


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _is_visual_step(action: dict[str, Any]) -> bool:
    """True if this step needs a Gemini box lookup via resolve_action."""
    op = action.get("op", "")
    if op not in _TARGET_OPS:
        return False
    target = action.get("target")
    if not isinstance(target, str) or not target.strip():
        return False
    # fly_to with a direction word is already a relative move — no visual target
    if target.lower() in _RELATIVE_DIRECTIONS:
        return False
    return True


def _empty_annotation() -> dict[str, Any]:
    return {"box_2d": [], "found": False, "confidence": 0.0}


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

async def annotate_steps(
    actions: list[dict],
    image_bytes: bytes,
    resolution_cache: dict | None = None,
) -> list[dict]:
    """Add box_2d + found + confidence to visual action dicts via resolve_action.

    resolution_cache: optional pre-computed {target_lower: ActionResolution}
    produced by a parallel resolve_action call started while FreeSolo was
    still running. Cache hits skip the Gemini round-trip for that target.

    Each visual step (fly_to|<target>, orbit|<target>, look_at|<target>) gets
    its own resolve_action() call with the op name as intent, so Gemini has
    the right context. Non-visual steps pass through unchanged.
    Unique targets are deduplicated — a cached result is reused for duplicates.
    """
    # Shallow-copy all actions; seed every step with empty box fields
    result_actions: list[dict[str, Any]] = [dict(a) for a in actions]
    for action in result_actions:
        action.update(_empty_annotation())

    # Identify visual steps
    visual_indices = [i for i, a in enumerate(result_actions) if _is_visual_step(a)]
    if not visual_indices:
        return result_actions  # no visual ops — skip Gemini entirely

    # Resolve each unique (target, op) pair concurrently.
    # Seed `seen` with any pre-computed results from the parallel pre-resolution
    # in voice_command_route — those targets won't generate a new Gemini call.
    seen: dict[str, Any] = dict(resolution_cache or {})  # target.lower() -> ActionResolution
    tasks = []
    keys = []
    for i in visual_indices:
        target = result_actions[i]["target"].strip()
        op = result_actions[i]["op"]
        key = target.lower()
        if key not in seen:
            seen[key] = None  # placeholder while resolving
            tasks.append(asyncio.to_thread(resolve_action, image_bytes, target, op))
            keys.append(key)

    try:
        results = await asyncio.wait_for(
            asyncio.gather(*tasks, return_exceptions=True),
            timeout=6.0,   # must fit in the overall <3s budget
        )
    except Exception as exc:
        logger.error("resolve_action gather failed: %s — visual steps get empty boxes", exc)
        return result_actions

    for key, result in zip(keys, results):
        if isinstance(result, Exception):
            logger.error("resolve_action failed for %r: %s", key, result)
        else:
            seen[key] = result

    # Merge results back into visual steps
    for i in visual_indices:
        target = result_actions[i]["target"].strip()
        resolution = seen.get(target.lower())
        if resolution is None or isinstance(resolution, Exception):
            continue
        result_actions[i]["box_2d"] = resolution.box_2d
        result_actions[i]["found"] = len(resolution.box_2d) == 4
        result_actions[i]["confidence"] = resolution.confidence
        logger.info(
            "annotate | target=%r action_type=%s found=%s confidence=%.2f reasoning=%r",
            target,
            resolution.action_type,
            result_actions[i]["found"],
            resolution.confidence,
            resolution.reasoning,
        )

    return result_actions
