"""OBJECTIVE JSON: the contract between the FreeSolo intent model and the planner.

The model emits:  {"steps": ["op|arg", ...], "confidence": 0.0-1.0}

Flat pipe-delimited step strings are deliberately simple so a small SFT'd
model reproduces them reliably. `normalize_objective` converts them into
structured action dicts consumed by the Gemini mission planner
(backend/planner.py), whose op vocabulary this file mirrors 1:1.

Step grammar (args after the op, `?` = optional):
  takeoff
  land
  fly_to|<target>
  fly_higher|<meters?>          default 2
  fly_lower|<meters?>           default 2
  fly_above|<target>
  rotate|<left|right>|<deg?>    default 90
  orbit|<target>|<revolutions?> default 1
  hover|<seconds?>              default 5
  look_at|<target>
  photo
  selfie
  panorama
  follow|<target>|<seconds?>    default 10
  return
  abort
  say|<text>
"""

from __future__ import annotations

import json
import re
from typing import Any

OPS = frozenset(
    {
        "takeoff",
        "land",
        "fly_to",
        "fly_higher",
        "fly_lower",
        "fly_above",
        "rotate",
        "orbit",
        "hover",
        "look_at",
        "photo",
        "selfie",
        "panorama",
        "follow",
        "return",
        "abort",
        "say",
    }
)

# Ops that take no arguments at all
NO_ARG_OPS = frozenset({"takeoff", "land", "photo", "selfie", "panorama", "return", "abort"})

# Ops whose first argument is a visual target the planner must ground
TARGET_OPS = frozenset({"fly_to", "fly_above", "orbit", "look_at", "follow"})

ROTATE_DIRECTIONS = frozenset({"left", "right"})

DEFAULT_ALTITUDE_M = 2.0
DEFAULT_ROTATE_DEG = 90.0
DEFAULT_HOVER_S = 5.0
DEFAULT_ORBIT_REVS = 1.0
DEFAULT_FOLLOW_S = 10.0

SYSTEM_PROMPT = """Convert the spoken drone command into OBJECTIVE JSON only. No markdown. No extra text.

Format:
{"steps":["op|arg","..."],"confidence":0.0-1.0}

steps is a JSON array of STRINGS: op, op|arg, or op|arg|arg2.

Valid ops and their args:
  takeoff
  land
  fly_to|<target>
  fly_higher|<meters>       (meters optional)
  fly_lower|<meters>        (meters optional)
  fly_above|<target>
  rotate|left|<degrees>     (degrees optional; direction is left or right)
  rotate|right|<degrees>
  orbit|<target>|<times>    (times optional)
  hover|<seconds>           (seconds optional)
  look_at|<target>
  photo
  selfie
  panorama
  follow|<target>|<seconds> (seconds optional)
  return
  abort
  say|<reply text>

Rules:
- Split compound commands into ordered steps.
- "come back / return / fly home" -> return
- "stop / cancel / abort" -> abort
- "take a picture of X" -> fly_to|X then photo.
- "look at X / point the camera at X" -> look_at|X
- "go up / higher" -> fly_higher, "go down / lower" -> fly_lower
- "turn/spin around" -> rotate|right|360 unless a direction/amount is given.
- Non-flight or unintelligible input -> single say step with a short reply.
- confidence reflects how sure you are of the whole plan.

Example output:
{"steps":["fly_to|red tent","photo","rotate|right|360","return"],"confidence":0.95}
"""


def dumps_objective(obj: dict[str, Any]) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def loads_objective(text: str) -> dict[str, Any] | None:
    """Extract the first JSON object from raw model output. None if unparseable."""
    if text is None:
        return None
    raw = text.strip()
    if not raw:
        return None
    # strip accidental tool/think tags
    raw = re.sub(r"</?(tool[_a-z]*|think(ing)?)>", "", raw, flags=re.I)
    fence = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", raw, flags=re.DOTALL)
    if fence:
        raw = fence.group(1)
    else:
        start, end = raw.find("{"), raw.rfind("}")
        if start >= 0 and end > start:
            raw = raw[start : end + 1]
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None
    return data if isinstance(data, dict) else None


def encode_step(op: str, *args: Any) -> str:
    parts = [op] + [str(a) for a in args if a is not None and str(a) != ""]
    return "|".join(parts)


def _float_or_none(v: str) -> float | None:
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def parse_step(step: str) -> dict[str, Any] | None:
    """One pipe-string step -> action dict. None when invalid."""
    if not isinstance(step, str) or not step.strip():
        return None
    parts = [p.strip() for p in step.split("|")]
    op = parts[0].lower()
    if op not in OPS:
        return None
    args = parts[1:]
    out: dict[str, Any] = {"op": op}

    if op in NO_ARG_OPS:
        return out

    if op in {"fly_to", "fly_above", "look_at"}:
        if not args or not args[0]:
            return None
        out["target"] = args[0]

    elif op in {"fly_higher", "fly_lower"}:
        meters = _float_or_none(args[0]) if args else None
        out["altitude_delta_m"] = abs(meters) if meters is not None else DEFAULT_ALTITUDE_M

    elif op == "rotate":
        if not args or args[0].lower() not in ROTATE_DIRECTIONS:
            return None
        direction = args[0].lower()
        deg = _float_or_none(args[1]) if len(args) > 1 else None
        deg = abs(deg) if deg is not None else DEFAULT_ROTATE_DEG
        out["direction"] = direction
        out["yaw_deg"] = deg if direction == "right" else -deg

    elif op == "orbit":
        if not args or not args[0]:
            return None
        out["target"] = args[0]
        revs = _float_or_none(args[1]) if len(args) > 1 else None
        out["revolutions"] = revs if revs and revs > 0 else DEFAULT_ORBIT_REVS

    elif op == "hover":
        secs = _float_or_none(args[0]) if args else None
        out["duration_s"] = secs if secs and secs > 0 else DEFAULT_HOVER_S

    elif op == "follow":
        if not args or not args[0]:
            return None
        out["target"] = args[0]
        secs = _float_or_none(args[1]) if len(args) > 1 else None
        out["duration_s"] = secs if secs and secs > 0 else DEFAULT_FOLLOW_S

    elif op == "say":
        if not args or not args[0]:
            return None
        out["text"] = "|".join(args)  # allow pipes inside spoken text

    return out


def normalize_objective(data: dict[str, Any]) -> dict[str, Any] | None:
    """Validate raw {"steps": [...]} and attach structured actions.

    Returns {"steps": [str], "actions": [dict], "confidence": float} or None.
    """
    steps_raw = data.get("steps")
    if not isinstance(steps_raw, list) or not steps_raw:
        return None
    steps: list[str] = []
    actions: list[dict[str, Any]] = []
    for item in steps_raw:
        if not isinstance(item, str):
            return None
        act = parse_step(item)
        if act is None:
            return None
        steps.append(item.strip())
        actions.append(act)
    try:
        conf = float(data.get("confidence", 0.8))
    except (TypeError, ValueError):
        conf = 0.8
    conf = max(0.0, min(1.0, conf))
    return {"steps": steps, "actions": actions, "confidence": conf}


def parse_and_normalize(text: str) -> dict[str, Any] | None:
    parsed = loads_objective(text)
    if parsed is None:
        return None
    return normalize_objective(parsed)


def score_objectives(predicted: dict[str, Any] | None, expected: dict[str, Any] | None) -> float:
    """Reward in [0,1]: op-sequence match, exact-step match, length agreement."""
    if predicted is None or expected is None:
        return 0.0
    ps, es = predicted.get("steps") or [], expected.get("steps") or []
    if not es:
        return 0.0
    n = min(len(ps), len(es))
    op_hits = sum(1 for i in range(n) if ps[i].split("|")[0] == es[i].split("|")[0])
    exact = sum(1 for i in range(n) if ps[i].lower().strip() == es[i].lower().strip())
    len_score = 1.0 - min(1.0, abs(len(ps) - len(es)) / max(len(es), 1))
    return max(0.0, min(1.0, 0.45 * (op_hits / len(es)) + 0.45 * (exact / len(es)) + 0.1 * len_score))


def make_objective(steps: list[str], confidence: float = 0.95) -> dict[str, Any]:
    """Build a serializable OBJECTIVE from step strings; raises on invalid steps."""
    obj = normalize_objective({"steps": steps, "confidence": confidence})
    if obj is None:
        raise ValueError(f"Invalid steps: {steps}")
    return {"steps": obj["steps"], "confidence": obj["confidence"]}
