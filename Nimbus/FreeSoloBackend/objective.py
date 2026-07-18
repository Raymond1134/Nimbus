"""OBJECTIVE JSON: sequential stick plans as flat string steps (robust for SFT)."""

from __future__ import annotations

import json
import re
from typing import Any

OPS = frozenset(
    {
        "fly_to",
        "fly_rel",
        "fly_through",
        "fly_under",
        "fly_over",
        "orbit",
        "return",
        "spin",
        "hover",
        "hover_station",
        "photo",
        "follow",
        "land",
        "abort",
        "say",
        "wait",
        "gimbal",
    }
)

DIRECTIONS = frozenset({"forward", "back", "left", "right", "up", "down"})

SYSTEM_PROMPT = """Convert the spoken drone command into OBJECTIVE JSON only. No markdown. No tool tags.

Format:
{"steps":["op|arg", "..."],"confidence":0.0-1.0}

steps is a JSON array of STRINGS. Each string is:
  op
  op|arg
  op|arg|arg2

Valid ops: fly_to, fly_rel, fly_through, fly_under, fly_over, orbit, return, spin, hover, hover_station, photo, follow, land, abort, say, wait, gimbal

Examples of step strings:
  fly_to|tree
  photo
  spin|360
  return
  hover|5
  fly_rel|forward|3
  orbit|picnic table|2
  follow|dog|10
  fly_under|bridge
  say|Ready.
  land
  abort

Example output:
{"steps":["fly_to|tree","photo","spin|360","return"],"confidence":0.95}
"""


def dumps_objective(obj: dict[str, Any]) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def loads_objective(text: str) -> dict[str, Any] | None:
    if text is None:
        return None
    raw = text.strip()
    if not raw:
        return None
    # strip accidental tool tags
    raw = re.sub(r"</?tool[_a-z]*>", "", raw, flags=re.I)
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


def parse_step(step: str) -> dict[str, Any] | None:
    if not isinstance(step, str) or not step.strip():
        return None
    parts = [p.strip() for p in step.split("|")]
    op = parts[0]
    if op not in OPS:
        return None
    out: dict[str, Any] = {"op": op}
    if op in {"fly_to", "fly_through", "fly_under", "fly_over"}:
        if len(parts) < 2:
            return None
        out["target"] = parts[1]
    elif op == "orbit":
        if len(parts) < 2:
            return None
        out["target"] = parts[1]
        if len(parts) >= 3:
            try:
                out["revolutions"] = float(parts[2])
            except ValueError:
                try:
                    out["duration_s"] = float(parts[2])
                except ValueError:
                    return None
    elif op == "follow":
        if len(parts) < 3:
            return None
        out["target"] = parts[1]
        out["duration_s"] = float(parts[2])
    elif op == "fly_rel":
        if len(parts) < 3:
            return None
        if parts[1] not in DIRECTIONS:
            return None
        out["direction"] = parts[1]
        try:
            out["distance_m"] = float(parts[2])
        except ValueError:
            out["duration_s"] = float(parts[2])
    elif op == "spin":
        out["yaw_deg"] = float(parts[1]) if len(parts) > 1 else 360.0
    elif op in {"hover", "wait"}:
        if len(parts) < 2:
            return None
        out["duration_s"] = float(parts[1])
    elif op == "say":
        if len(parts) < 2:
            return None
        out["text"] = parts[1]
    elif op == "gimbal":
        if len(parts) < 2:
            return None
        out["pitch_deg"] = float(parts[1])
    return out


def normalize_objective(data: dict[str, Any]) -> dict[str, Any] | None:
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
    if predicted is None or expected is None:
        return 0.0
    ps, es = predicted.get("steps") or [], expected.get("steps") or []
    if not es:
        return 0.0
    n = min(len(ps), len(es))
    hits = sum(1 for i in range(n) if ps[i].split("|")[0] == es[i].split("|")[0])
    exact = sum(1 for i in range(n) if ps[i] == es[i])
    len_score = 1.0 - min(1.0, abs(len(ps) - len(es)) / max(len(es), 1))
    return max(0.0, min(1.0, 0.5 * (hits / len(es)) + 0.4 * (exact / len(es)) + 0.1 * len_score))


def make_objective(steps: list[str], confidence: float = 0.95) -> dict[str, Any]:
    obj = normalize_objective({"steps": steps, "confidence": confidence})
    if obj is None:
        raise ValueError(f"Invalid steps: {steps}")
    # store only what we train on
    return {"steps": obj["steps"], "confidence": obj["confidence"]}
