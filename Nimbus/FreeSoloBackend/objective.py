"""OBJECTIVE JSON schema helpers shared by the FreeSolo env and dataset scripts."""

from __future__ import annotations

import json
import re
from typing import Any

INTENTS = (
    "seek_and_photo",
    "hover_station",
    "return_to_station",
    "land",
    "abort",
    "say",
)

SEEK_INTENTS = frozenset({"seek_and_photo"})
REQUIRED_KEYS = ("intent", "target", "say_text", "constraints", "confidence")

SYSTEM_PROMPT = """You convert a spoken drone command (raw speech-to-text) into OBJECTIVE JSON.

Output ONLY a single JSON object. No markdown. No commentary.

Schema:
{
  "intent": "seek_and_photo" | "hover_station" | "return_to_station" | "land" | "abort" | "say",
  "target": string | null,
  "say_text": string | null,
  "constraints": {
    "max_seconds": number (optional),
    "max_radius_m": number (optional)
  },
  "confidence": number between 0 and 1
}

Rules:
- Emit exactly one intent.
- seek_and_photo: set target to a short noun phrase (what to find/photograph). Use max_seconds=45 and max_radius_m=30 unless the user specifies otherwise.
- hover_station / return_to_station / land / abort: target=null, say_text=null, constraints={} unless needed.
- say: use when the utterance is unclear, off-topic, or needs a spoken reply. Put the reply in say_text. target=null.
- Do not invent stick velocities, waypoints, or camera servo steps. That is a later planner's job.
- Tolerate noisy STT (typos, missing words). Prefer a best-effort intent with lower confidence over refusing.
- If truly impossible to interpret, intent=say with a short clarifying question in say_text.
"""


def dumps_objective(obj: dict[str, Any]) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def loads_objective(text: str) -> dict[str, Any] | None:
    """Parse OBJECTIVE JSON from model output; tolerate optional markdown fences."""
    if text is None:
        return None
    raw = text.strip()
    if not raw:
        return None

    fence = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", raw, flags=re.DOTALL)
    if fence:
        raw = fence.group(1)
    else:
        start = raw.find("{")
        end = raw.rfind("}")
        if start >= 0 and end > start:
            raw = raw[start : end + 1]

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict):
        return None
    return data


def normalize_objective(data: dict[str, Any]) -> dict[str, Any] | None:
    """Coerce a dict into the canonical OBJECTIVE shape, or None if invalid."""
    intent = data.get("intent")
    if intent not in INTENTS:
        return None

    target = data.get("target", None)
    if target is not None and not isinstance(target, str):
        return None
    if isinstance(target, str):
        target = target.strip() or None

    say_text = data.get("say_text", None)
    if say_text is not None and not isinstance(say_text, str):
        return None
    if isinstance(say_text, str):
        say_text = say_text.strip() or None

    constraints = data.get("constraints", {})
    if constraints is None:
        constraints = {}
    if not isinstance(constraints, dict):
        return None
    clean_constraints: dict[str, float] = {}
    for key in ("max_seconds", "max_radius_m"):
        if key in constraints and constraints[key] is not None:
            try:
                clean_constraints[key] = float(constraints[key])
            except (TypeError, ValueError):
                return None

    confidence = data.get("confidence", 0.5)
    try:
        confidence = float(confidence)
    except (TypeError, ValueError):
        return None
    confidence = max(0.0, min(1.0, confidence))

    if intent in SEEK_INTENTS and not target:
        return None
    if intent == "say" and not say_text:
        return None
    if intent not in SEEK_INTENTS:
        target = None
    if intent != "say":
        say_text = None
    if intent == "seek_and_photo":
        clean_constraints.setdefault("max_seconds", 45.0)
        clean_constraints.setdefault("max_radius_m", 30.0)

    return {
        "intent": intent,
        "target": target,
        "say_text": say_text,
        "constraints": clean_constraints,
        "confidence": confidence,
    }


def parse_and_normalize(text: str) -> dict[str, Any] | None:
    parsed = loads_objective(text)
    if parsed is None:
        return None
    return normalize_objective(parsed)


def score_objectives(predicted: dict[str, Any] | None, expected: dict[str, Any] | None) -> float:
    """Reward in [0, 1] for FreeSolo GRPO / local eval."""
    if predicted is None or expected is None:
        return 0.0

    score = 0.0
    if predicted["intent"] == expected["intent"]:
        score += 0.6
    else:
        return 0.0

    if expected["intent"] in SEEK_INTENTS:
        pred_t = (predicted.get("target") or "").strip().lower()
        exp_t = (expected.get("target") or "").strip().lower()
        if pred_t == exp_t:
            score += 0.3
        elif exp_t and (exp_t in pred_t or pred_t in exp_t):
            score += 0.15
    elif expected["intent"] == "say":
        pred_s = (predicted.get("say_text") or "").strip().lower()
        exp_s = (expected.get("say_text") or "").strip().lower()
        if pred_s and exp_s and (exp_s in pred_s or pred_s in exp_s):
            score += 0.3
        elif pred_s:
            score += 0.1
    else:
        score += 0.3

    # Small bonus for being valid JSON with confidence present
    if "confidence" in predicted:
        score += 0.1

    return min(1.0, score)


def make_objective(
    intent: str,
    *,
    target: str | None = None,
    say_text: str | None = None,
    max_seconds: float | None = None,
    max_radius_m: float | None = None,
    confidence: float = 0.95,
) -> dict[str, Any]:
    constraints: dict[str, float] = {}
    if intent == "seek_and_photo":
        constraints["max_seconds"] = float(max_seconds if max_seconds is not None else 45)
        constraints["max_radius_m"] = float(max_radius_m if max_radius_m is not None else 30)
    elif max_seconds is not None:
        constraints["max_seconds"] = float(max_seconds)
    elif max_radius_m is not None:
        constraints["max_radius_m"] = float(max_radius_m)

    obj = {
        "intent": intent,
        "target": target,
        "say_text": say_text,
        "constraints": constraints,
        "confidence": float(confidence),
    }
    normalized = normalize_objective(obj)
    if normalized is None:
        raise ValueError(f"Invalid OBJECTIVE: {obj}")
    return normalized
