"""OBJECTIVE → mid-level InstructionSteps + Gemini visual grounding.

The app implements these behaviors on Virtual Stick. Gemini's job is mostly
vision: attach box_2d to anything that names a place/thing, and expand FreeSolo
OBJECTIVE into an ordered list of these ops.

Supported ops (sequential):
  fly_to       — approach a grounded target
  fly_higher   — climb (altitude_delta_m or duration_s)
  fly_lower    — descend
  fly_above    — go above a grounded target and hold
  rotate       — yaw left/right (direction or yaw_deg)
  orbit        — circle a grounded target
  hover        — hold position
  look_at      — gimbal toward target / pitch_deg
  photo        — take picture
  takeoff      — startTakeoff
  land         — startLanding
  selfie       — back up, turn to face operator, photo
  panorama     — 360 yaw + photos
  follow       — track a grounded target for duration_s
  abort / say  — stop / spoken reply (FreeSolo parity)
"""

from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path
from typing import Any

from dotenv import load_dotenv
from google import genai
from google.genai import types
from pydantic import BaseModel, Field

from grounding import ground_target, preprocess_image

load_dotenv(Path(__file__).resolve().parent / ".env")

logger = logging.getLogger(__name__)

_MAX_ATTEMPTS = 2

_VALID_OPS = frozenset({
    "fly_to", "fly_higher", "fly_lower", "fly_above",
    "rotate", "orbit", "hover", "look_at", "photo",
    "takeoff", "land", "selfie", "panorama", "follow",
    "abort", "say",
})

_VISUAL_OPS = frozenset({
    "fly_to", "fly_above", "orbit", "look_at", "follow", "selfie",
})

# Accidental low-level / legacy leftovers → nearest mid-level op
_OP_ALIASES: dict[str, str] = {
    "approach": "fly_to",
    "stick": "fly_to",
    "spin": "rotate",
    "turn": "rotate",
    "gimbal": "look_at",
    "fly_over": "fly_above",
    "fly_up": "fly_higher",
    "fly_down": "fly_lower",
    "ascend": "fly_higher",
    "descend": "fly_lower",
    "fly_through": "fly_to",
    "fly_under": "fly_to",
    "hover_station": "hover",
    "wait": "hover",
    "return": "fly_to",  # app may special-case notes="return"
    "take_photo": "photo",
    "picture": "photo",
    "pano": "panorama",
    # Directional relative moves → fly_to (direction/distance_m set by objective parser)
    "fly_forward": "fly_to",  "move_forward": "fly_to",  "go_forward": "fly_to",
    "fly_backward": "fly_to", "fly_back": "fly_to",     "move_backward": "fly_to",
    "fly_left": "fly_to",    "move_left": "fly_to",     "strafe_left": "fly_to",
    "fly_right": "fly_to",   "move_right": "fly_to",    "strafe_right": "fly_to",
}


class InstructionStep(BaseModel):
    """One mid-level flight/camera instruction for the app to implement."""

    id: int
    op: str

    # Visual target (grounded by Gemini / resolve_step)
    target: str | None = None
    found: bool = False
    box_2d: list[int] = Field(default_factory=list)  # [ymin,xmin,ymax,xmax] 0–1000
    needs_grounding: bool = False
    grounding_confidence: float = 0.0

    # Motion params
    direction: str | None = None       # rotate: left|right; relative hints
    distance_m: float | None = None
    altitude_delta_m: float | None = None
    duration_s: float | None = None
    yaw_deg: float | None = None       # rotate signed (+CW) or absolute spin
    revolutions: float | None = None   # orbit
    radius_m: float | None = None      # orbit
    standoff_m: float = 3.0            # fly_to / fly_above / follow
    gimbal_pitch_deg: float | None = None  # look_at without a box

    text: str | None = None            # say
    notes: str = ""


class MissionPlan(BaseModel):
    steps: list[InstructionStep]
    confidence: float = 0.0
    blocked: bool = False
    block_reason: str = ""
    planner: str = "gemini"  # gemini | fallback


_PLAN_PROMPT = """You are the mission planner for a DJI Mavic Mini voice drone.

You receive:
1) OBJECTIVE JSON — ordered high-level actions from FreeSolo (WHAT).
2) Current drone camera frame.

Emit a MissionPlan: an ordered list of InstructionSteps the APP will execute.
You do NOT emit Virtual Stick velocities. The app implements each op.

Allowed op values ONLY:
  fly_to       — fly toward target; set standoff_m (default 3)
  fly_higher   — climb; set altitude_delta_m (meters) or duration_s
  fly_lower    — descend; set altitude_delta_m or duration_s
  fly_above    — go above target and hold; needs target + box when visible
  rotate       — yaw in place; direction "left"|"right" and/or yaw_deg (+CW, −CCW)
  orbit        — circle target; radius_m, revolutions or duration_s
  hover        — hold; duration_s
  look_at      — aim gimbal at target (box) or gimbal_pitch_deg
  photo        — take a picture
  takeoff      — take off
  land         — land
  selfie       — back away from subject/operator, turn to face them, photo
  panorama     — full 360 yaw sweep with photos
  follow       — track target for duration_s
  abort        — stop
  say          — spoken reply in text

Vision rules:
- For ops that name a thing/place (fly_to, fly_above, orbit, look_at, follow, selfie):
  if visible in the frame → found=true, box_2d=[ymin,xmin,ymax,xmax] normalized 0-1000,
  needs_grounding=false, grounding_confidence 0–1.
  if NOT visible → found=false, box_2d=[], needs_grounding=true.
- photo / takeoff / land / hover / rotate / fly_higher / fly_lower / panorama:
  usually no box unless a target is named.
- fly_to with direction ("forward"/"back"/"left"/"right") and NO target → relative move;
  found=false, needs_grounding=false, preserve distance_m from the objective.

Expansion rules:
- OBJECTIVE actions use the SAME op names as your steps (plus "return").
  Mostly translate 1:1; preserve order; refine parameters using the frame.
- rotate: keep the given direction/yaw_deg (right = +CW, left = −CCW).
- "selfie" → single selfie step (app expands the motion).
- "return" → fly_to target="operator" with notes="return_home" (needs_grounding likely).
- Number steps id from 0.
- blocked=true only if the first visual step's target is missing from the frame.
- confidence ≈ OBJECTIVE confidence.
- notes: short optional hint.

OBJECTIVE:
{objective_json}
"""


def _client() -> genai.Client:
    return genai.Client(api_key=os.environ["GEMINI_API_KEY"])


def _as_float(v: Any) -> float | None:
    if v is None:
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _objective_actions(objective: dict[str, Any]) -> list[dict[str, Any]]:
    actions = objective.get("actions")
    if not isinstance(actions, list):
        return []
    return [a for a in actions if isinstance(a, dict) and a.get("op")]


def _needs_box(op: str, target: str | None) -> bool:
    return op in _VISUAL_OPS and bool(target)


def expand_objective_skeleton(objective: dict[str, Any]) -> list[InstructionStep]:
    """Deterministic OBJECTIVE → mid-level steps (no vision). Fallback path.

    OBJECTIVE actions come from the FreeSolo intent model (see
    objective.parse_step) and map ~1:1 onto InstructionSteps; this path
    only runs when Gemini planning fails.
    """
    steps: list[InstructionStep] = []
    idx = 0

    def push(**kwargs: Any) -> None:
        nonlocal idx
        op = kwargs["op"]
        target = kwargs.get("target")
        kwargs.setdefault("needs_grounding", _needs_box(op, target))
        steps.append(InstructionStep(id=idx, **kwargs))
        idx += 1

    for action in _objective_actions(objective):
        raw = str(action.get("op", "")).lower().strip()
        raw = _OP_ALIASES.get(raw, raw) if raw not in {"return"} else raw
        target = action.get("target")
        if isinstance(target, str):
            target = target.strip() or None
        else:
            target = None
        duration = _as_float(action.get("duration_s"))
        altitude = _as_float(action.get("altitude_delta_m")) or _as_float(action.get("distance_m"))
        yaw_deg = _as_float(action.get("yaw_deg"))
        pitch_deg = _as_float(action.get("pitch_deg"))
        revolutions = _as_float(action.get("revolutions"))
        direction = action.get("direction") if isinstance(action.get("direction"), str) else None

        if raw == "fly_to":
            # Relative directional move if no visual target but direction is set
            direction = action.get("direction") if isinstance(action.get("direction"), str) else None
            dist = _as_float(action.get("distance_m"))
            if direction and not target:
                push(op="fly_to", direction=direction, distance_m=dist)
            else:
                push(op="fly_to", target=target, standoff_m=3.0,
                     direction=direction, distance_m=dist)

        elif raw == "fly_above":
            push(op="fly_above", target=target, standoff_m=3.0)

        elif raw == "fly_higher":
            push(op="fly_higher", altitude_delta_m=altitude or 2.0, duration_s=duration)

        elif raw == "fly_lower":
            push(op="fly_lower", altitude_delta_m=altitude or 2.0, duration_s=duration)

        elif raw == "rotate":
            deg = yaw_deg
            if deg is None:
                deg = -90.0 if direction == "left" else 90.0
            push(op="rotate", yaw_deg=deg, direction="left" if deg < 0 else "right")

        elif raw == "orbit":
            push(
                op="orbit",
                target=target,
                revolutions=revolutions or 1.0,
                duration_s=duration,
                radius_m=5.0,
            )

        elif raw == "hover":
            push(op="hover", duration_s=duration or 5.0)

        elif raw == "look_at":
            if target:
                push(op="look_at", target=target)
            else:
                push(op="look_at", gimbal_pitch_deg=pitch_deg if pitch_deg is not None else -30.0)

        elif raw == "photo":
            push(op="photo")

        elif raw == "takeoff":
            push(op="takeoff")

        elif raw == "land":
            push(op="land")

        elif raw == "selfie":
            push(op="selfie", target="operator", standoff_m=3.0)

        elif raw == "panorama":
            push(op="panorama")

        elif raw == "follow":
            push(op="follow", target=target, duration_s=duration or 10.0, standoff_m=3.0)

        elif raw == "abort":
            push(op="abort")

        elif raw == "return":
            push(op="fly_to", target="operator", notes="return_home", standoff_m=2.0)

        elif raw == "say":
            text = action.get("text") if isinstance(action.get("text"), str) else "Okay."
            push(op="say", text=text)

        else:
            push(op="say", text=f"Unsupported objective op: {raw}")

    return steps


def _attach_groundings(
    steps: list[InstructionStep],
    image_bytes: bytes,
) -> list[InstructionStep]:
    cache: dict[str, Any] = {}
    for step in steps:
        if not _needs_box(step.op, step.target):
            step.needs_grounding = False
            continue
        assert step.target is not None
        key = step.target.lower()
        if key not in cache:
            cache[key] = ground_target(image_bytes, step.target)
        g = cache[key]
        if g.found and g.box_2d:
            step.found = True
            step.box_2d = list(g.box_2d)
            step.grounding_confidence = g.confidence
            step.needs_grounding = False
            if g.label and not step.notes:
                step.notes = f"grounded as '{g.label}'"
        else:
            step.found = False
            step.box_2d = []
            step.grounding_confidence = 0.0
            step.needs_grounding = True
    return steps


def _finalize_plan(
    steps: list[InstructionStep],
    objective: dict[str, Any],
    planner: str,
) -> MissionPlan:
    conf = _as_float(objective.get("confidence"))
    if conf is None:
        conf = 0.8

    blocked = False
    block_reason = ""
    for step in steps:
        if step.needs_grounding and step.target:
            blocked = True
            block_reason = f"Target not in frame: '{step.target}'"
            break
        if _needs_box(step.op, step.target):
            break

    pending = sum(1 for s in steps if s.needs_grounding)
    if pending:
        conf = max(0.2, conf - 0.1 * pending)

    return MissionPlan(
        steps=steps,
        confidence=conf,
        blocked=blocked,
        block_reason=block_reason,
        planner=planner,
    )


def _sanitize_plan(plan: MissionPlan) -> MissionPlan:
    for i, step in enumerate(plan.steps):
        op = (step.op or "").lower().strip()
        op = _OP_ALIASES.get(op, op)
        if op not in _VALID_OPS:
            op = "hover"
            step.notes = (step.notes + " | sanitized unknown op").strip(" |")
        step.op = op
        step.id = i
        if step.found and step.box_2d:
            step.needs_grounding = False
        elif _needs_box(op, step.target) and not step.found:
            step.needs_grounding = True
        else:
            step.needs_grounding = bool(step.needs_grounding and step.target)
        # Defaults
        if op == "orbit" and step.radius_m is None:
            step.radius_m = 5.0
        if op == "rotate" and step.yaw_deg is None:
            if step.direction == "left":
                step.yaw_deg = -90.0
            elif step.direction == "right":
                step.yaw_deg = 90.0
            else:
                step.yaw_deg = 90.0
        if op in {"fly_to", "fly_above", "follow"} and step.standoff_m <= 0:
            step.standoff_m = 3.0
        if op == "follow" and step.duration_s is None:
            step.duration_s = 10.0
        if op == "hover" and step.duration_s is None:
            step.duration_s = 2.0
        if op in {"fly_higher", "fly_lower"} and step.altitude_delta_m is None:
            step.altitude_delta_m = 2.0
    plan.planner = plan.planner or "gemini"
    return plan


def _plan_with_gemini(
    objective: dict[str, Any],
    image_bytes: bytes,
) -> MissionPlan | None:
    if not os.environ.get("GEMINI_API_KEY", "").strip():
        logger.info("GEMINI_API_KEY unset — skipping Gemini planner")
        return None

    try:
        processed = preprocess_image(image_bytes)
    except ValueError as exc:
        logger.warning("Plan image preprocess failed: %s", exc)
        return None

    prompt = _PLAN_PROMPT.format(
        objective_json=json.dumps(objective, ensure_ascii=False),
    )
    try:
        client = _client()
    except KeyError:
        logger.info("GEMINI_API_KEY missing — skipping Gemini planner")
        return None
    last_exc: Exception | None = None

    for attempt in range(1, _MAX_ATTEMPTS + 1):
        t0 = time.time()
        try:
            response = client.models.generate_content(
                model="gemini-flash-latest",
                contents=[
                    types.Part.from_bytes(data=processed, mime_type="image/jpeg"),
                    prompt,
                ],
                config=types.GenerateContentConfig(
                    response_mime_type="application/json",
                    response_schema=MissionPlan,
                ),
            )
            elapsed_ms = (time.time() - t0) * 1000
            plan = _sanitize_plan(MissionPlan.model_validate_json(response.text))
            logger.info(
                "Gemini plan ok | attempt=%d steps=%d blocked=%s latency=%.0fms",
                attempt,
                len(plan.steps),
                plan.blocked,
                elapsed_ms,
            )
            return plan
        except Exception as exc:
            elapsed_ms = (time.time() - t0) * 1000
            last_exc = exc
            logger.warning(
                "Gemini plan failed | attempt=%d latency=%.0fms error=%s",
                attempt,
                elapsed_ms,
                exc,
            )

    logger.error("All Gemini plan attempts failed: %s", last_exc)
    return None


def plan_mission(objective: dict[str, Any], image_bytes: bytes) -> MissionPlan:
    """Convert OBJECTIVE + frame → mid-level MissionPlan with grounded boxes."""
    if not _objective_actions(objective):
        return MissionPlan(
            steps=[InstructionStep(id=0, op="say", text="I didn't catch a command.")],
            confidence=0.0,
            blocked=True,
            block_reason="Empty OBJECTIVE",
            planner="fallback",
        )

    plan = _plan_with_gemini(objective, image_bytes)
    if plan is not None and plan.steps:
        return plan

    logger.info("Using deterministic expand + grounding fallback")
    steps = expand_objective_skeleton(objective)
    steps = _attach_groundings(steps, image_bytes)
    return _finalize_plan(steps, objective, planner="fallback")


def resolve_step(
    step: InstructionStep | dict[str, Any],
    image_bytes: bytes,
) -> InstructionStep:
    """Re-ground one visual step against a fresh frame."""
    if isinstance(step, dict):
        step = InstructionStep.model_validate(step)

    if not step.target or step.op not in _VISUAL_OPS:
        step.needs_grounding = False
        return step

    g = ground_target(image_bytes, step.target)
    if g.found and g.box_2d:
        step.found = True
        step.box_2d = list(g.box_2d)
        step.grounding_confidence = g.confidence
        step.needs_grounding = False
        step.notes = f"resolved as '{g.label}'" if g.label else "resolved"
    else:
        step.found = False
        step.box_2d = []
        step.grounding_confidence = 0.0
        step.needs_grounding = True
        step.notes = "target still not found"
    return step
