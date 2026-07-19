"""OBJECTIVE JSON: the contract between the FreeSolo intent model and the planner.

The model emits:  {"steps": ["op|arg", ...], "confidence": 0.0-1.0}

Flat pipe-delimited step strings are deliberately simple so a small SFT'd
model reproduces them reliably. `normalize_objective` converts them into
structured action dicts consumed by the Gemini mission planner
(backend/planner.py), whose op vocabulary this file mirrors 1:1.

Step grammar (args after the op, `?` = optional):
  takeoff
  land
  fly_to|<target>                 visual approach to a named object/place
  fly_direction|forward|<meters?> relative nudge forward   (default 0.5 m)
  fly_direction|back|<meters?>    relative nudge backward
  fly_direction|left|<meters?>    relative nudge left
  fly_direction|right|<meters?>   relative nudge right
  change_altitude|<+/-meters?>    + = climb, - = descend   (default +0.5 m)
  rotate|<left|right>|<deg?>      yaw in place             (default right|90)
  orbit|<target>|<revolutions?>   circle target            (default 1 rev)
  hover|<seconds?>                hold position            (default 5 s)
  look_at|<target>                aim gimbal at target
  photo
  selfie
  panorama
  follow|<target>|<seconds?>      track target             (default 30 s)
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
        "fly_direction",
        "change_altitude",
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
# (these get Gemini visual annotation).
TARGET_OPS = frozenset({"fly_to", "orbit", "look_at", "follow"})

ROTATE_DIRECTIONS = frozenset({"left", "right"})

# Direction words that signal a relative horizontal move (no visual target).
# Used in parse_step when fly_to|<dir>|N or a directional alias is seen.
_RELATIVE_DIRECTIONS = frozenset({"forward", "back", "backward", "left", "right"})

# Directional alias op → canonical direction string (all resolve to fly_direction).
_DIRECTION_ALIASES: dict[str, str] = {
    "fly_forward":   "forward",
    "move_forward":  "forward",
    "go_forward":    "forward",
    "fly_backward":  "back",
    "fly_back":      "back",
    "move_backward": "back",
    "go_backward":   "back",
    "move_back":     "back",
    "fly_left":      "left",
    "move_left":     "left",
    "go_left":       "left",
    "strafe_left":   "left",
    "fly_right":     "right",
    "move_right":    "right",
    "go_right":      "right",
    "strafe_right":  "right",
}

# Altitude alias op → sign (+1 climb / -1 descend). All resolve to change_altitude.
_ALTITUDE_ALIASES: dict[str, int] = {
    "fly_higher": +1,
    "fly_up":     +1,
    "ascend":     +1,
    "climb":      +1,
    "fly_lower":  -1,
    "fly_down":   -1,
    "descend":    -1,
}

# Near-miss ops the model may invent → closest valid op. Used only in
# lenient (inference) mode — training rewards stay strict.
OP_ALIASES: dict[str, str] = {
    "fly_behind": "fly_to",
    "fly_past": "fly_to",
    "fly_toward": "fly_to",
    "fly_towards": "fly_to",
    "fly_over": "fly_to",
    "fly_under": "fly_to",
    "fly_through": "fly_to",
    "go_to": "fly_to",
    "approach": "fly_to",
    "spin": "rotate",
    "turn": "rotate",
    "yaw": "rotate",
    "circle": "orbit",
    "look": "look_at",
    "point_at": "look_at",
    "aim": "look_at",
    "watch": "look_at",
    "gimbal": "look_at",
    "take_photo": "photo",
    "take_picture": "photo",
    "picture": "photo",
    "snap": "photo",
    "dronie": "selfie",
    "pano": "panorama",
    "track": "follow",
    "take_off": "takeoff",
    "launch": "takeoff",
    "come_back": "return",
    "fly_home": "return",
    "return_home": "return",
    "go_home": "return",
    "rth": "return",
    "stop": "abort",
    "cancel": "abort",
    "halt": "abort",
    "wait": "hover",
    "hold": "hover",
    "hover_station": "hover",
    # Directional relative moves (all → fly_direction; parse_step injects direction)
    **{k: "fly_direction" for k in _DIRECTION_ALIASES},
    # Altitude moves (all → change_altitude; parse_step injects sign)
    **{k: "change_altitude" for k in _ALTITUDE_ALIASES},
}

DEFAULT_NUDGE_M = 0.5
DEFAULT_ALTITUDE_M = 0.5
DEFAULT_HOVER_S = 5.0
DEFAULT_ORBIT_REVS = 1.0
DEFAULT_FOLLOW_S = 30.0
DEFAULT_ROTATE_DEG = 90.0

SYSTEM_PROMPT = """Convert the spoken drone command into OBJECTIVE JSON only. No markdown. No extra text.

Format:
{"steps":["op","op|arg","op|arg|arg2"],"confidence":0.0-1.0}

Valid ops:
  takeoff
  land
  fly_to|<target>                 target = visible object or place
  fly_direction|forward|<meters>  relative nudge (omit meters for 0.5 m default)
  fly_direction|back|<meters>
  fly_direction|left|<meters>
  fly_direction|right|<meters>
  change_altitude|<+/-meters>     + climb, - descend (omit for ±0.5 m default)
  rotate|left|<degrees>           (omit degrees for 90)
  rotate|right|<degrees>
  orbit|<target>|<revolutions>    (omit revolutions for 1)
  hover|<seconds>                 (omit for 5)
  look_at|<target>
  photo
  selfie
  panorama
  follow|<target>|<seconds>       (omit for 30)
  return
  abort
  say|<reply>

Rules:
- Split compound commands into ordered steps.
- "launch/take off/lift off/go up and hover/liftoff" → takeoff  (NEVER land)
- "land/touch down/come down/set down/put it down" → land  (NEVER takeoff)
- "come back/return/fly home" → return
- "stop/cancel/abort" → abort
- "take a picture of X" → fly_to|X then photo
- "look at X/point camera at X" → look_at|X
- "go up/higher [N]" → change_altitude|+N (convert feet: 1 ft = 0.3 m)
- "go down/lower [N]" → change_altitude|-N
- "fly forward/back/left/right [N feet/meters]" → fly_direction|forward|N (convert feet to meters)
- "turn/spin around" → rotate|right|360 unless direction given
- When no distance given for nudge/altitude: omit the value (app defaults to 0.5 m)
- Non-flight or unintelligible → say|<short reply>

Example:
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


def parse_step(step: str, lenient: bool = False) -> dict[str, Any] | None:
    """One pipe-string step -> action dict. None when invalid.

    lenient=True additionally maps near-miss op names (e.g. "fly_behind")
    onto the closest valid op — use at inference, never for training rewards.
    """
    if not isinstance(step, str) or not step.strip():
        return None
    parts = [p.strip() for p in step.split("|")]
    op = parts[0].lower().replace(" ", "_")
    if op not in OPS:
        if not lenient:
            return None
        orig_op = op  # preserve before alias lookup
        op = OP_ALIASES.get(op, "")
        if op not in OPS:
            return None
        # Directional alias (fly_forward|2 etc.) → fly_direction with direction.
        if op == "fly_direction" and orig_op in _DIRECTION_ALIASES:
            direction = _DIRECTION_ALIASES[orig_op]
            dist = _float_or_none(parts[1]) if len(parts) > 1 else None
            result: dict[str, Any] = {"op": "fly_direction", "direction": direction}
            if dist is not None and dist > 0:
                result["distance_m"] = dist
            return result
        # Altitude alias (fly_higher|2 etc.) → change_altitude with signed delta
        if op == "change_altitude" and orig_op in _ALTITUDE_ALIASES:
            sign = _ALTITUDE_ALIASES[orig_op]
            mag = _float_or_none(parts[1]) if len(parts) > 1 else None
            mag = abs(mag) if mag is not None else DEFAULT_ALTITUDE_M
            return {"op": "change_altitude", "delta_m": sign * mag}
        # special case: bare "spin|360" style args parse as rotate deg
        if op == "rotate" and parts[1:] and parts[1].lower() not in ROTATE_DIRECTIONS:
            parts = [op, "right"] + parts[1:]
        else:
            parts = [op] + parts[1:]
    args = parts[1:]
    out: dict[str, Any] = {"op": op}

    if op in NO_ARG_OPS:
        return out

    if op == "fly_direction":
        if not args or not args[0]:
            return None
        direction = args[0].strip().lower()
        if direction not in _RELATIVE_DIRECTIONS:
            return None
        if direction == "backward":
            direction = "back"
        dist = _float_or_none(args[1]) if len(args) > 1 else None
        result = {"op": "fly_direction", "direction": direction}
        if dist is not None and dist > 0:
            result["distance_m"] = dist
        return result

    if op in {"fly_to", "look_at"}:
        if not args or not args[0]:
            return None
        target = args[0].strip()
        # Legacy compatibility: fly_to|forward|N maps to fly_direction.
        if op == "fly_to" and target.lower() in _RELATIVE_DIRECTIONS:
            direction = "back" if target.lower() == "backward" else target.lower()
            dist = _float_or_none(args[1]) if len(args) > 1 else None
            result = {"op": "fly_direction", "direction": direction}
            if dist is not None and dist > 0:
                result["distance_m"] = dist
            return result
        out["target"] = target

    elif op == "change_altitude":
        delta = _float_or_none(args[0]) if args else None
        out["delta_m"] = delta if delta is not None else DEFAULT_ALTITUDE_M

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


def normalize_objective(data: dict[str, Any], lenient: bool = False) -> dict[str, Any] | None:
    """Validate raw {"steps": [...]} and attach structured actions.

    strict (default): any invalid step invalidates the whole objective — used
    for training rewards. lenient: near-miss ops are aliased and unsalvageable
    steps are dropped; None only when nothing valid remains.

    Returns {"steps": [str], "actions": [dict], "confidence": float} or None.
    """
    steps_raw = data.get("steps")
    if not isinstance(steps_raw, list) or not steps_raw:
        return None
    steps: list[str] = []
    actions: list[dict[str, Any]] = []
    for item in steps_raw:
        if not isinstance(item, str):
            if lenient:
                continue
            return None
        act = parse_step(item, lenient=lenient)
        if act is None:
            if lenient:
                continue
            return None
        steps.append(item.strip())
        actions.append(act)
    if not actions:
        return None
    try:
        conf = float(data.get("confidence", 0.8))
    except (TypeError, ValueError):
        conf = 0.8
    conf = max(0.0, min(1.0, conf))
    return {"steps": steps, "actions": actions, "confidence": conf}


def parse_and_normalize(text: str, lenient: bool = False) -> dict[str, Any] | None:
    parsed = loads_objective(text)
    if parsed is None:
        return None
    return normalize_objective(parsed, lenient=lenient)


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
