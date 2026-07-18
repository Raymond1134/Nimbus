"""OBJECTIVE JSON: the contract between the FreeSolo intent model and the backend.

The model emits:  {"steps": ["op|arg", ...], "confidence": 0.0-1.0}

Flat pipe-delimited step strings are deliberately simple so a small SFT'd
model reproduces them reliably. `normalize_objective` converts them into
structured action dicts consumed by the annotator (backend/annotator.py).

Step grammar (14 ops, `?` = optional):
  takeoff
  land
  fly_to|<target>
  fly_to|<forward|back|left|right>|<meters?>   relative nudge (default 0.5 m)
  change_altitude|<+/-meters?>                  + = climb, - = descend (default +0.5)
  rotate|<left|right>|<degrees?>               default right|90
  orbit|<target>|<revolutions?>                default 1
  hover|<seconds?>                             default 5
  look_at|<target>
  photo
  selfie
  panorama
  follow|<target>|<seconds?>                   default 30
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

# Ops whose first argument is a visual target the annotator must ground
TARGET_OPS = frozenset({"fly_to", "orbit", "look_at", "follow"})

ROTATE_DIRECTIONS = frozenset({"left", "right"})

# Direction words that signal a relative horizontal move (no visual target)
_RELATIVE_DIRECTIONS = frozenset({"forward", "back", "backward", "left", "right"})

# Defaults
DEFAULT_NUDGE_M = 0.5
DEFAULT_ALTITUDE_M = 0.5
DEFAULT_HOVER_S = 5.0
DEFAULT_ORBIT_REVS = 1.0
DEFAULT_FOLLOW_S = 30.0
DEFAULT_ROTATE_DEG = 90.0

# Altitude-positive aliases (lenient → change_altitude positive delta)
_ALTITUDE_POS_ALIASES = frozenset({"fly_higher", "fly_up", "ascend", "climb"})
# Altitude-negative aliases (lenient → change_altitude negative delta)
_ALTITUDE_NEG_ALIASES = frozenset({"fly_lower", "fly_down", "descend"})
# Directional aliases (lenient → fly_to with direction injected)
_DIRECTIONAL_ALIASES: dict[str, str] = {
    "fly_forward":   "forward",
    "move_forward":  "forward",
    "go_forward":    "forward",
    "fly_backward":  "back",
    "fly_back":      "back",
    "move_backward": "back",
    "move_back":     "back",
    "go_backward":   "back",
    "fly_left":      "left",
    "move_left":     "left",
    "go_left":       "left",
    "strafe_left":   "left",
    "fly_right":     "right",
    "move_right":    "right",
    "go_right":      "right",
    "strafe_right":  "right",
}

# Near-miss ops the model may invent → closest valid op. Used only in
# lenient (inference) mode — training rewards stay strict.
OP_ALIASES: dict[str, str] = {
    # Altitude
    "fly_higher":    "change_altitude",
    "fly_up":        "change_altitude",
    "ascend":        "change_altitude",
    "climb":         "change_altitude",
    "fly_lower":     "change_altitude",
    "fly_down":      "change_altitude",
    "descend":       "change_altitude",
    # Visual fly_to
    "fly_behind":    "fly_to",
    "fly_past":      "fly_to",
    "fly_toward":    "fly_to",
    "fly_towards":   "fly_to",
    "fly_over":      "fly_to",
    "fly_under":     "fly_to",
    "fly_through":   "fly_to",
    "go_to":         "fly_to",
    "approach":      "fly_to",
    # Directional relative fly_to (parse_step injects direction)
    **{k: "fly_to" for k in _DIRECTIONAL_ALIASES},
    # Rotate
    "spin":          "rotate",
    "turn":          "rotate",
    "yaw":           "rotate",
    # Orbit
    "circle":        "orbit",
    # Look_at
    "look":          "look_at",
    "point_at":      "look_at",
    "aim":           "look_at",
    "watch":         "look_at",
    "gimbal":        "look_at",
    # Photo
    "take_photo":    "photo",
    "take_picture":  "photo",
    "picture":       "photo",
    "snap":          "photo",
    # Selfie
    "dronie":        "selfie",
    # Panorama
    "pano":          "panorama",
    # Follow
    "track":         "follow",
    # Takeoff
    "take_off":      "takeoff",
    "launch":        "takeoff",
    # Return
    "come_back":     "return",
    "fly_home":      "return",
    "return_home":   "return",
    "go_home":       "return",
    "rth":           "return",
    # Abort
    "stop":          "abort",
    "cancel":        "abort",
    "halt":          "abort",
    # Hover
    "wait":          "hover",
    "hold":          "hover",
    "hover_station": "hover",
}

SYSTEM_PROMPT = """Convert the spoken drone command into OBJECTIVE JSON only. No markdown. No extra text.

Format:
{"steps":["op","op|arg","op|arg|arg2"],"confidence":0.0-1.0}

Valid ops:
  takeoff
  land
  fly_to|<target>                 target = visible object or place
  fly_to|forward|<meters>         relative nudge (omit meters for 0.5 m default)
  fly_to|back|<meters>
  fly_to|left|<meters>
  fly_to|right|<meters>
  change_altitude|<+/-meters>     + climb, - descend (omit for \u00b10.5 m default)
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
- "come back/return/fly home" \u2192 return
- "stop/cancel/abort" \u2192 abort
- "take a picture of X" \u2192 fly_to|X then photo
- "look at X/point camera at X" \u2192 look_at|X
- "go up/higher [N]" \u2192 change_altitude|+N (convert feet: 1 ft = 0.3 m)
- "go down/lower [N]" \u2192 change_altitude|-N
- "fly forward/back/left/right [N feet/meters]" \u2192 fly_to|forward|N (convert feet to meters)
- "turn/spin around" \u2192 rotate|right|360 unless direction given
- When no distance given for nudge/altitude: omit the value (app defaults to 0.5 m)
- Non-flight or unintelligible \u2192 say|<short reply>

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
    """One pipe-string step → action dict. None when invalid.

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
        orig_op = op
        op = OP_ALIASES.get(op, "")
        if op not in OPS:
            return None

        # Altitude-positive aliases → change_altitude with positive delta
        if orig_op in _ALTITUDE_POS_ALIASES:
            meters = _float_or_none(parts[1]) if len(parts) > 1 else None
            delta = abs(meters) if meters is not None else DEFAULT_ALTITUDE_M
            return {"op": "change_altitude", "delta_m": delta}

        # Altitude-negative aliases → change_altitude with negative delta
        if orig_op in _ALTITUDE_NEG_ALIASES:
            meters = _float_or_none(parts[1]) if len(parts) > 1 else None
            delta = -abs(meters) if meters is not None else -DEFAULT_ALTITUDE_M
            return {"op": "change_altitude", "delta_m": delta}

        # Directional aliases → fly_to with direction injected
        if op == "fly_to" and orig_op in _DIRECTIONAL_ALIASES:
            direction = _DIRECTIONAL_ALIASES[orig_op]
            dist = _float_or_none(parts[1]) if len(parts) > 1 else None
            result: dict[str, Any] = {"op": "fly_to", "direction": direction}
            if dist is not None and dist > 0:
                result["distance_m"] = dist
            return result

        # Rotate aliases (spin/turn/yaw) with no direction → default right|90
        if op == "rotate":
            if not parts[1:] or parts[1].lower() not in ROTATE_DIRECTIONS:
                if parts[1:] and _float_or_none(parts[1]) is not None:
                    # e.g. spin|360 → rotate|right|360
                    parts = [op, "right"] + parts[1:]
                else:
                    parts = [op, "right", str(DEFAULT_ROTATE_DEG)]
            else:
                parts = [op] + parts[1:]
        else:
            parts = [op] + parts[1:]

    args = parts[1:]
    out: dict[str, Any] = {"op": op}

    if op in NO_ARG_OPS:
        return out

    if op == "fly_to":
        if not args or not args[0]:
            return None
        target = args[0].strip()
        # fly_to|forward|N — relative move with no visual target
        if target.lower() in _RELATIVE_DIRECTIONS:
            direction = "back" if target.lower() == "backward" else target.lower()
            dist = _float_or_none(args[1]) if len(args) > 1 else None
            result = {"op": "fly_to", "direction": direction}
            if dist is not None and dist > 0:
                result["distance_m"] = dist
            return result
        out["target"] = target

    elif op == "look_at":
        if not args or not args[0]:
            return None
        out["target"] = args[0].strip()

    elif op == "change_altitude":
        # Parse signed float; positive = climb, negative = descend.
        # No arg → default +0.5 m (climb).
        if args and args[0]:
            val = _float_or_none(args[0])
            out["delta_m"] = val if val is not None else DEFAULT_ALTITUDE_M
        else:
            out["delta_m"] = DEFAULT_ALTITUDE_M

    elif op == "rotate":
        if not args or args[0].lower() not in ROTATE_DIRECTIONS:
            if lenient:
                out["direction"] = "right"
                out["yaw_deg"] = DEFAULT_ROTATE_DEG
                return out
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
