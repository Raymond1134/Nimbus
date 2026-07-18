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

SYSTEM_PROMPT = """You convert a spoken drone command (raw speech-to-text) into OBJECTIVE JSON.

Output ONLY one JSON object. No markdown. No commentary.

CRITICAL: "actions" MUST be a JSON array of objects. Never a string. Never a flat object.
Example: {"actions":[{"op":"fly_to","target":"tree"},{"op":"photo"},{"op":"return"}],"confidence":0.95}

Schema:
{
  "actions": [ Action, ... ],
  "confidence": number 0..1
}

Action is an object with "op" and optional fields:
  fly_to       { "op":"fly_to", "target":"<short noun phrase>" }
  fly_rel      { "op":"fly_rel", "direction":"forward|back|left|right|up|down", "distance_m"?:number, "duration_s"?:number }
  fly_through  { "op":"fly_through", "target":"..." }
  fly_under    { "op":"fly_under", "target":"..." }
  fly_over     { "op":"fly_over", "target":"..." }
  orbit        { "op":"orbit", "target":"...", "revolutions"?:number, "duration_s"?:number }
  return       { "op":"return" }                    // back to operator station
  spin         { "op":"spin", "yaw_deg":number }    // signed degrees (+ = CW looking down)
  hover        { "op":"hover", "duration_s":number } // hover in place
  hover_station{ "op":"hover_station" }             // hold over operator
  photo        { "op":"photo" }
  follow       { "op":"follow", "target":"...", "duration_s":number }
  land         { "op":"land" }
  abort        { "op":"abort" }                     // stop / cancel
  say          { "op":"say", "text":"..." }         // spoken reply
  wait         { "op":"wait", "duration_s":number }
  gimbal       { "op":"gimbal", "pitch_deg":number }

Rules:
- Emit an ordered action list that captures the FULL command, including "then / and / after".
- Prefer short targets ("red tent", "oak tree") — no stick velocities or waypoints.
- "come back / return / fly back to me" → return
- "stop / abort / cancel" → single abort action
- "take a picture / snap a photo" → photo
- "spin / turn / rotate / twirl" → spin with yaw_deg (default 360 if unspecified)
- "hover for N seconds" → hover; "just hover / stay" without time → hover_station
- "follow X for N seconds" → follow
- "fly under / through / over X" → fly_under / fly_through / fly_over
- "orbit / circle around X" → orbit
- Unclear / off-topic → [{"op":"say","text":"..."}]
- Tolerate noisy STT. Best-effort plan with lower confidence beats refusing.
- Do NOT invent constraints, max radius, or safety envelopes.
"""


def dumps_objective(obj: dict[str, Any]) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def loads_objective(text: str) -> dict[str, Any] | None:
    if text is None:
        return None
    raw = text.strip()
    if not raw:
        return None
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


def _num(v: Any) -> float | None:
    if v is None:
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def normalize_action(raw: Any) -> dict[str, Any] | None:
    if not isinstance(raw, dict):
        return None
    op = raw.get("op")
    if op not in OPS:
        return None

    out: dict[str, Any] = {"op": op}

    if op in {"fly_to", "fly_through", "fly_under", "fly_over", "orbit", "follow"}:
        target = raw.get("target")
        if not isinstance(target, str) or not target.strip():
            return None
        out["target"] = target.strip()

    if op == "fly_rel":
        direction = raw.get("direction")
        if direction not in DIRECTIONS:
            return None
        out["direction"] = direction
        dm = _num(raw.get("distance_m"))
        ds = _num(raw.get("duration_s"))
        if dm is not None:
            out["distance_m"] = dm
        if ds is not None:
            out["duration_s"] = ds
        if dm is None and ds is None:
            out["distance_m"] = 3.0

    if op == "spin":
        yaw = _num(raw.get("yaw_deg"))
        if yaw is None:
            yaw = 360.0
        out["yaw_deg"] = yaw

    if op in {"hover", "wait", "follow"}:
        ds = _num(raw.get("duration_s"))
        if op == "follow":
            if ds is None:
                ds = 10.0
            out["duration_s"] = ds
        elif op in {"hover", "wait"}:
            if ds is None:
                return None
            out["duration_s"] = ds

    if op == "orbit":
        rev = _num(raw.get("revolutions"))
        ds = _num(raw.get("duration_s"))
        if rev is not None:
            out["revolutions"] = rev
        if ds is not None:
            out["duration_s"] = ds

    if op == "say":
        text = raw.get("text")
        if not isinstance(text, str) or not text.strip():
            return None
        out["text"] = text.strip()

    if op == "gimbal":
        pitch = _num(raw.get("pitch_deg"))
        if pitch is None:
            return None
        out["pitch_deg"] = pitch

    return out


def normalize_objective(data: dict[str, Any]) -> dict[str, Any] | None:
    actions_raw = data.get("actions")
    if not isinstance(actions_raw, list) or not actions_raw:
        return None
    actions: list[dict[str, Any]] = []
    for item in actions_raw:
        act = normalize_action(item)
        if act is None:
            return None
        actions.append(act)

    conf = _num(data.get("confidence"))
    if conf is None:
        conf = 0.8
    conf = max(0.0, min(1.0, conf))
    return {"actions": actions, "confidence": conf}


def parse_and_normalize(text: str) -> dict[str, Any] | None:
    parsed = loads_objective(text)
    if parsed is None:
        return None
    return normalize_objective(parsed)


def _action_key(a: dict[str, Any]) -> tuple:
    return (
        a.get("op"),
        (a.get("target") or "").lower(),
        a.get("direction"),
        round(float(a["yaw_deg"]), 1) if "yaw_deg" in a else None,
        round(float(a["duration_s"]), 1) if "duration_s" in a else None,
        round(float(a["distance_m"]), 1) if "distance_m" in a else None,
        round(float(a["pitch_deg"]), 1) if "pitch_deg" in a else None,
        round(float(a["revolutions"]), 1) if "revolutions" in a else None,
        (a.get("text") or "").lower(),
    )


def score_objectives(predicted: dict[str, Any] | None, expected: dict[str, Any] | None) -> float:
    if predicted is None or expected is None:
        return 0.0
    pa, ea = predicted["actions"], expected["actions"]
    if not ea:
        return 0.0

    # Length similarity
    len_score = 1.0 - min(1.0, abs(len(pa) - len(ea)) / max(len(ea), 1))
    n = min(len(pa), len(ea))
    if n == 0:
        return 0.1 * len_score

    op_hits = 0.0
    detail_hits = 0.0
    for i in range(n):
        p, e = pa[i], ea[i]
        if p.get("op") == e.get("op"):
            op_hits += 1.0
            pk, ek = _action_key(p), _action_key(e)
            if pk == ek:
                detail_hits += 1.0
            else:
                # Soft target match
                pt = (p.get("target") or "").lower()
                et = (e.get("target") or "").lower()
                if et and pt and (et in pt or pt in et):
                    detail_hits += 0.6
                elif p.get("direction") == e.get("direction") and e.get("op") == "fly_rel":
                    detail_hits += 0.5
                else:
                    detail_hits += 0.25
        else:
            break  # prefix must align

    op_frac = op_hits / len(ea)
    detail_frac = detail_hits / len(ea)
    score = 0.55 * op_frac + 0.35 * detail_frac + 0.10 * len_score
    return max(0.0, min(1.0, score))


def make_objective(actions: list[dict[str, Any]], confidence: float = 0.95) -> dict[str, Any]:
    obj = normalize_objective({"actions": actions, "confidence": confidence})
    if obj is None:
        raise ValueError(f"Invalid OBJECTIVE actions: {actions}")
    return obj
