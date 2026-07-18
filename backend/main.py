"""Nimbus Grounding + Mission Planner API.

Pipeline:
  Voice → ElevenLabs STT → FreeSolo OBJECTIVE → Gemini plan_mission
  → mid-level InstructionStep[] (with box_2d) → app implements each op.

Ops: fly_to, fly_higher, fly_lower, fly_above, rotate, orbit, hover,
look_at, photo, takeoff, land, selfie, panorama, follow (+ abort/say).

Gemini's main job is vision grounding + sequencing. The iOS app owns
Virtual Stick execution for each op.
"""

import json
import logging
import os
import re
import time
import traceback

import httpx
import uvicorn
from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from grounding import GroundingResult, ground_target
from planner import InstructionStep, MissionPlan, plan_mission, resolve_step

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger(__name__)

_MAX_BYTES = 10 * 1024 * 1024  # 10 MB

# FreeSolo integration config
_FREESOLO_URL = os.getenv("FREESOLO_ENDPOINT_URL", "")
_FREESOLO_TIMEOUT = 10.0
_USE_MOCK = os.getenv("USE_FREESOLO_MOCK", "true").lower() == "true"

app = FastAPI(title="Nimbus Grounding API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------------------------------------------------------------------------
# FreeSolo helpers — returns OBJECTIVE {actions, confidence}
# ---------------------------------------------------------------------------

_TRIGGER_WORDS = (
    "find", "locate", "photograph", "photo of", "picture of",
    "look for", "search for", "go to", "fly to", "move to",
    "towards", "toward", "at", "to", "the",
)
_FILLER = frozenset({
    "a", "an", "the", "me", "please", "some", "that", "this",
    "it", "them", "they", "him", "her", "us", "one",
})


def _extract_target_phrase(transcript: str) -> str | None:
    text = transcript.lower().strip()
    for trigger in sorted(_TRIGGER_WORDS, key=len, reverse=True):
        pattern = rf"\b{re.escape(trigger)}\s+(.+)"
        m = re.search(pattern, text)
        if m:
            remainder = m.group(1).split()
            content = [w for w in remainder if w not in _FILLER]
            if content:
                stop = {"and", "or", "but", "near", "by", "with", "in", "on", "of", "then"}
                phrase_words: list[str] = []
                for w in content:
                    if w in stop:
                        break
                    phrase_words.append(w)
                if phrase_words:
                    return " ".join(phrase_words[:4])
    return None


def _mock_freesolo_objective(transcript: str) -> dict:
    """Best-effort OBJECTIVE from keyword rules (dev without FreeSolo).

    Real FreeSolo returns the same shape — ordered actions + confidence.
    """
    text = transcript.lower().strip()

    # Instant single-op commands
    if re.search(r"\b(abort|stop|cancel)\b", text):
        return {"actions": [{"op": "abort"}], "confidence": 0.95}
    if re.search(r"\b(land|landing)\b", text) and "fly" not in text:
        return {"actions": [{"op": "land"}], "confidence": 0.95}
    if re.search(r"\b(return|come back|fly back|go home)\b", text) and not _extract_target_phrase(text):
        return {"actions": [{"op": "return"}], "confidence": 0.9}
    if re.search(r"\b(hover|hold station|stay)\b", text) and not _extract_target_phrase(text):
        return {"actions": [{"op": "hover_station"}], "confidence": 0.9}

    actions: list[dict] = []
    target = _extract_target_phrase(transcript)

    # Compound: fly/find + photo
    wants_photo = bool(re.search(r"\b(photo|picture|photograph|snap)\b", text))
    wants_return = bool(re.search(r"\b(return|come back|fly back)\b", text))
    wants_spin = bool(re.search(r"\b(spin|twirl|rotate|turn around)\b", text))

    if target:
        actions.append({"op": "fly_to", "target": target})
        if wants_photo:
            actions.append({"op": "photo"})
        if wants_spin:
            actions.append({"op": "spin", "yaw_deg": 360.0})
        if wants_return:
            actions.append({"op": "return"})
    elif wants_photo:
        actions.append({"op": "photo"})
    elif wants_spin:
        actions.append({"op": "spin", "yaw_deg": 360.0})
    else:
        actions.append({
            "op": "say",
            "text": "I didn't catch a clear flight command.",
        })

    return {"actions": actions, "confidence": 0.85 if target else 0.5}


def _normalize_freesolo_payload(data: dict) -> dict:
    """Accept either new OBJECTIVE or legacy intent dict from FreeSolo."""
    if isinstance(data.get("actions"), list):
        conf = data.get("confidence", 0.8)
        try:
            conf = float(conf)
        except (TypeError, ValueError):
            conf = 0.8
        return {"actions": data["actions"], "confidence": conf}

    # Legacy: {intent, target, say_text, constraints, confidence}
    intent = (data.get("intent") or "").strip()
    target = data.get("target")
    conf = data.get("confidence", 0.8)
    try:
        conf = float(conf)
    except (TypeError, ValueError):
        conf = 0.8

    actions: list[dict]
    if intent == "seek_and_photo":
        actions = []
        if target:
            actions.append({"op": "fly_to", "target": str(target)})
        actions.append({"op": "photo"})
    elif intent == "hover_station":
        actions = [{"op": "hover_station"}]
    elif intent in {"return_to_station", "return"}:
        actions = [{"op": "return"}]
    elif intent == "land":
        actions = [{"op": "land"}]
    elif intent == "abort":
        actions = [{"op": "abort"}]
    elif intent == "say":
        actions = [{"op": "say", "text": data.get("say_text") or "Okay."}]
    else:
        actions = [{"op": "fly_to", "target": str(target or "object")}]

    return {"actions": actions, "confidence": conf}


async def _call_freesolo_real(transcript: str) -> dict:
    async with httpx.AsyncClient(timeout=_FREESOLO_TIMEOUT) as client:
        resp = await client.post(_FREESOLO_URL, json={"transcript": transcript})
        resp.raise_for_status()
        return resp.json()


async def _get_objective(transcript: str) -> dict:
    if _USE_MOCK:
        objective = _mock_freesolo_objective(transcript)
        logger.info("[MOCK] FreeSolo OBJECTIVE | %s", objective)
        return objective

    try:
        raw = await _call_freesolo_real(transcript)
    except (httpx.ConnectError, httpx.TimeoutException) as exc:
        raise HTTPException(
            status_code=502,
            detail={"error": "FreeSolo service unreachable", "detail": str(exc)},
        ) from exc
    except httpx.HTTPStatusError as exc:
        raise HTTPException(
            status_code=502,
            detail={
                "error": "FreeSolo service returned an error",
                "detail": str(exc),
                "freesolo_status": exc.response.status_code,
            },
        ) from exc

    objective = _normalize_freesolo_payload(raw)
    logger.info("FreeSolo OBJECTIVE: %s", objective)
    return objective


def _first_target(objective: dict) -> str | None:
    for action in objective.get("actions") or []:
        if isinstance(action, dict):
            t = action.get("target")
            if isinstance(t, str) and t.strip():
                return t.strip()
    return None


def _legacy_intent_fields(objective: dict, plan: MissionPlan) -> dict:
    """Compat fields for the current iOS BackendVoiceCommandResponse decoder."""
    actions = objective.get("actions") or []
    ops = [a.get("op") for a in actions if isinstance(a, dict)]

    if "abort" in ops:
        intent = "abort"
    elif ops == ["land"] or (len(ops) == 1 and ops[0] == "land"):
        intent = "land"
    elif ops == ["return"] or (len(ops) == 1 and ops[0] == "return"):
        intent = "return_to_station"
    elif ops == ["hover_station"] or (len(ops) == 1 and ops[0] == "hover_station"):
        intent = "hover_station"
    elif ops and ops[0] == "say":
        intent = "say"
    else:
        intent = "seek_and_photo"

    say_text = None
    for a in actions:
        if isinstance(a, dict) and a.get("op") == "say":
            say_text = a.get("text")
            break

    # Prefer first grounded visual step for legacy box fields
    found = False
    box_2d: list[int] = []
    label = ""
    gconf = 0.0
    for step in plan.steps:
        if step.found and step.box_2d:
            found = True
            box_2d = step.box_2d
            label = step.target or ""
            gconf = step.grounding_confidence
            break

    return {
        "intent": intent,
        "target": _first_target(objective),
        "say_text": say_text,
        "constraints": {"max_seconds": 45.0, "max_radius_m": 30.0},
        "confidence": objective.get("confidence", plan.confidence),
        "found": found,
        "box_2d": box_2d,
        "label": label,
        "grounding_confidence": gconf,
    }


async def _read_image(image: UploadFile) -> tuple[bytes, str]:
    content_type = image.content_type or ""
    if not content_type.startswith("image/"):
        raise HTTPException(
            status_code=400,
            detail="File must be an image (image/* content type required).",
        )
    image_bytes = await image.read()
    if len(image_bytes) > _MAX_BYTES:
        raise HTTPException(status_code=413, detail="Image too large. Maximum size is 10 MB.")
    return image_bytes, content_type


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.post("/ground_target", response_model=GroundingResult)
async def ground_target_route(
    image: UploadFile = File(...),
    target_description: str = Form(...),
) -> GroundingResult:
    try:
        image_bytes, content_type = await _read_image(image)

        if not target_description.strip():
            raise HTTPException(status_code=400, detail="target_description must not be empty.")

        t0 = time.time()
        result = ground_target(image_bytes, target_description, content_type)
        elapsed_ms = (time.time() - t0) * 1000

        logger.info(
            "Request complete | target=%r found=%s confidence=%.2f total_latency=%.0fms",
            target_description,
            result.found,
            result.confidence,
            elapsed_ms,
        )
        return result

    except HTTPException:
        raise
    except Exception:
        logger.error("Unhandled error in /ground_target:\n%s", traceback.format_exc())
        return GroundingResult(found=False, box_2d=[], label="", confidence=0.0)


@app.post("/plan_mission", response_model=MissionPlan)
async def plan_mission_route(
    image: UploadFile = File(...),
    objective_json: str = Form(..., description="FreeSolo OBJECTIVE JSON string"),
) -> MissionPlan:
    """OBJECTIVE + current frame → sequential InstructionStep plan.

    Use this when the app already has OBJECTIVE from FreeSolo and just needs
    Gemini to ground targets and emit executable steps.
    """
    try:
        image_bytes, _ = await _read_image(image)
        try:
            objective = json.loads(objective_json)
        except json.JSONDecodeError as exc:
            raise HTTPException(status_code=400, detail=f"Invalid objective_json: {exc}") from exc
        if not isinstance(objective, dict):
            raise HTTPException(status_code=400, detail="objective_json must be a JSON object")

        objective = _normalize_freesolo_payload(objective)
        t0 = time.time()
        plan = plan_mission(objective, image_bytes)
        logger.info(
            "plan_mission | steps=%d blocked=%s planner=%s latency=%.0fms",
            len(plan.steps),
            plan.blocked,
            plan.planner,
            (time.time() - t0) * 1000,
        )
        return plan
    except HTTPException:
        raise
    except Exception:
        logger.error("Unhandled error in /plan_mission:\n%s", traceback.format_exc())
        raise HTTPException(status_code=500, detail="plan_mission failed") from None


@app.post("/resolve_step", response_model=InstructionStep)
async def resolve_step_route(
    image: UploadFile = File(...),
    step_json: str = Form(..., description="InstructionStep JSON to re-ground"),
) -> InstructionStep:
    """Re-ground one step against a fresh frame (deferred / tracker-lost)."""
    try:
        image_bytes, _ = await _read_image(image)
        try:
            step_data = json.loads(step_json)
        except json.JSONDecodeError as exc:
            raise HTTPException(status_code=400, detail=f"Invalid step_json: {exc}") from exc

        t0 = time.time()
        resolved = resolve_step(step_data, image_bytes)
        logger.info(
            "resolve_step | id=%s op=%s found=%s conf=%.2f latency=%.0fms",
            resolved.id,
            resolved.op,
            resolved.found,
            resolved.grounding_confidence,
            (time.time() - t0) * 1000,
        )
        return resolved
    except HTTPException:
        raise
    except Exception:
        logger.error("Unhandled error in /resolve_step:\n%s", traceback.format_exc())
        raise HTTPException(status_code=500, detail="resolve_step failed") from None


@app.post("/voice_command")
async def voice_command_route(
    transcript: str = Form(...),
    image: UploadFile = File(...),
) -> JSONResponse:
    """Full pipeline: transcript → FreeSolo OBJECTIVE → Gemini MissionPlan.

    Response includes both the new `objective` + `plan` fields and legacy
    intent/grounding fields so the current iOS client keeps working.
    """
    try:
        image_bytes, _ = await _read_image(image)

        logger.info(
            "voice_command | mode=%s transcript=%r",
            "MOCK" if _USE_MOCK else "LIVE",
            transcript,
        )

        try:
            objective = await _get_objective(transcript)
        except HTTPException as exc:
            detail = exc.detail if isinstance(exc.detail, dict) else {"error": str(exc.detail)}
            return JSONResponse(status_code=exc.status_code, content=detail)

        t0 = time.time()
        plan = plan_mission(objective, image_bytes)
        elapsed_ms = (time.time() - t0) * 1000

        logger.info(
            "Plan complete | steps=%d blocked=%s planner=%s latency=%.0fms",
            len(plan.steps),
            plan.blocked,
            plan.planner,
            elapsed_ms,
        )

        legacy = _legacy_intent_fields(objective, plan)
        return JSONResponse(content={
            **legacy,
            "objective": objective,
            "plan": plan.model_dump(),
        })

    except HTTPException:
        raise
    except Exception:
        logger.error("Unhandled error in /voice_command:\n%s", traceback.format_exc())
        return JSONResponse(
            status_code=500,
            content={"error": "Internal server error", "detail": traceback.format_exc()},
        )


if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
