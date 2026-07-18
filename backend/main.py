"""Nimbus Grounding + Mission Planner API.

Pipeline:
  Voice → ElevenLabs STT → FreeSolo OBJECTIVE → Gemini plan_mission
  → mid-level InstructionStep[] (with box_2d) → app implements each op.

Ops: fly_to, fly_higher, fly_lower, fly_above, rotate, orbit, hover,
look_at, photo, takeoff, land, selfie, panorama, follow, return
(+ abort/say).

FreeSolo (fine-tuned intent model, OpenAI-compatible endpoint) owns
text → OBJECTIVE. Gemini owns vision grounding + sequencing. The iOS
app owns Virtual Stick execution for each op.
"""

import json
import logging
import os
import re
import time
import traceback
from pathlib import Path

import httpx
import uvicorn
from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from grounding import GroundingResult, ground_target
from objective import (
    SYSTEM_PROMPT,
    make_objective,
    normalize_objective,
    parse_and_normalize,
)
from planner import InstructionStep, MissionPlan, plan_mission, resolve_step

_BACKEND_ROOT = Path(__file__).resolve().parent
load_dotenv(_BACKEND_ROOT / ".env")
load_dotenv(_BACKEND_ROOT.parent / "Nimbus" / "FreeSoloBackend" / ".env")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger(__name__)

_MAX_BYTES = 10 * 1024 * 1024  # 10 MB

# FreeSolo deployed adapter (OpenAI-compatible). From `flash deployments --json`.
_FREESOLO_BASE_URL = os.getenv("FREESOLO_BASE_URL", "").rstrip("/")
_FREESOLO_API_KEY = os.getenv("FREESOLO_API_KEY", "")
_FREESOLO_MODEL = os.getenv("FREESOLO_MODEL", "")
_FREESOLO_TIMEOUT = 15.0
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

_TARGET_TRIGGERS = (
    "fly to", "go to", "head to", "find", "approach", "fly towards", "fly toward",
    "orbit", "circle", "fly around", "look at", "point the camera at", "aim at",
    "follow", "track", "fly above", "get above", "hover above",
    "picture of", "photo of", "shot of", "photograph",
)
_FILLER = frozenset({"a", "an", "the", "that", "this", "me", "please", "some"})
_STOP = frozenset({
    "and", "or", "but", "then", "near", "by", "with", "of",
    "once", "twice", "times", "for",
})


def _extract_target_phrase(transcript: str) -> str | None:
    text = transcript.lower().strip()
    for trigger in sorted(_TARGET_TRIGGERS, key=len, reverse=True):
        m = re.search(rf"\b{re.escape(trigger)}\s+(.+)", text)
        if not m:
            continue
        words = [w for w in m.group(1).split() if w not in _FILLER]
        phrase: list[str] = []
        for w in words:
            if w in _STOP:
                break
            phrase.append(w)
        if phrase:
            return " ".join(phrase[:4])
    return None


def _mock_freesolo_objective(transcript: str) -> dict:
    """Best-effort OBJECTIVE from keyword rules (dev without FreeSolo).

    Mirrors the deployed model's contract: pipe-string steps + confidence,
    normalized to include structured actions.
    """
    text = transcript.lower().strip()
    target = _extract_target_phrase(transcript)

    def obj(steps: list[str], conf: float) -> dict:
        normalized = normalize_objective(make_objective(steps, conf))
        assert normalized is not None
        return normalized

    # Instant single-op commands
    if re.search(r"\b(abort|stop|cancel|halt|never mind)\b", text):
        return obj(["abort"], 0.95)
    if re.search(r"\b(take ?off|lift off|launch)\b", text):
        return obj(["takeoff"], 0.95)
    if re.search(r"\bland\b", text) and "fly" not in text:
        return obj(["land"], 0.95)
    if re.search(r"\b(return|come back|fly back|come home|fly home)\b", text) and not target:
        return obj(["return"], 0.9)
    if re.search(r"\bselfie|picture of me|photo of me|dronie\b", text):
        return obj(["selfie"], 0.9)
    if re.search(r"\b(panorama|pano|360 photo)\b", text):
        return obj(["panorama"], 0.9)
    if re.search(r"\b(hover|hold position|stay put|hold station)\b", text) and not target:
        return obj(["hover"], 0.9)
    if re.search(r"\b(higher|go up|climb|fly up)\b", text) and not target:
        return obj(["fly_higher"], 0.85)
    if re.search(r"\b(lower|go down|descend|fly down)\b", text) and not target:
        return obj(["fly_lower"], 0.85)

    steps: list[str] = []
    wants_photo = bool(re.search(r"\b(photo|picture|pic|photograph|snap|shot)\b", text))
    wants_return = bool(re.search(r"\b(return|come back|fly back)\b", text))
    wants_spin = bool(re.search(r"\b(spin|twirl|turn around|360)\b", text))
    wants_orbit = bool(re.search(r"\b(orbit|circle|fly around|loop around)\b", text))
    wants_follow = bool(re.search(r"\b(follow|track|tail)\b", text))
    wants_look = bool(re.search(r"\b(look at|aim at|point)\b", text))

    if target:
        if wants_follow:
            steps.append(f"follow|{target}")
        elif wants_orbit:
            steps.append(f"orbit|{target}")
        elif wants_look and not wants_photo:
            steps.append(f"look_at|{target}")
        else:
            steps.append(f"fly_to|{target}")
        if wants_photo:
            steps.append("photo")
        if wants_spin:
            steps.append("rotate|right|360")
        if wants_return:
            steps.append("return")
    elif wants_photo:
        steps.append("photo")
    elif wants_spin:
        steps.append("rotate|right|360")
    else:
        return normalize_objective(
            {"steps": ["say|I didn't catch a clear flight command."], "confidence": 0.5}
        )

    return obj(steps, 0.85 if target else 0.6)


def _normalize_freesolo_payload(data: dict) -> dict:
    """Accept OBJECTIVE as steps-strings or pre-structured actions."""
    conf = data.get("confidence", 0.8)
    try:
        conf = float(conf)
    except (TypeError, ValueError):
        conf = 0.8

    # Canonical: {"steps": ["op|arg", ...]}
    if isinstance(data.get("steps"), list):
        normalized = normalize_objective(data, lenient=True)
        if normalized is not None:
            return normalized
        logger.warning("Invalid steps in OBJECTIVE payload: %s", data.get("steps"))

    # Already-structured actions (e.g. from plan_mission callers)
    if isinstance(data.get("actions"), list):
        return {"actions": data["actions"], "confidence": conf}

    return {
        "actions": [{"op": "say", "text": "I couldn't parse that command."}],
        "confidence": 0.0,
    }


async def _call_freesolo_real(transcript: str) -> str:
    """Chat-completions call to the deployed FreeSolo adapter; returns raw text."""
    if not (_FREESOLO_BASE_URL and _FREESOLO_API_KEY and _FREESOLO_MODEL):
        raise HTTPException(
            status_code=503,
            detail={"error": "FreeSolo not configured",
                    "detail": "Set FREESOLO_BASE_URL, FREESOLO_API_KEY, FREESOLO_MODEL"},
        )
    payload = {
        "model": _FREESOLO_MODEL,
        "temperature": 0.0,
        "max_tokens": 256,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": transcript},
        ],
        "response_format": {"type": "json_object"},
    }
    async with httpx.AsyncClient(timeout=_FREESOLO_TIMEOUT) as client:
        resp = await client.post(
            f"{_FREESOLO_BASE_URL}/chat/completions",
            json=payload,
            headers={"Authorization": f"Bearer {_FREESOLO_API_KEY}"},
        )
        resp.raise_for_status()
        body = resp.json()
    return (body.get("choices") or [{}])[0].get("message", {}).get("content") or ""


async def _get_objective(transcript: str) -> dict:
    if _USE_MOCK:
        objective = _mock_freesolo_objective(transcript)
        logger.info("[MOCK] FreeSolo OBJECTIVE | %s", objective)
        return objective

    try:
        raw_text = await _call_freesolo_real(transcript)
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

    objective = parse_and_normalize(raw_text, lenient=True)
    if objective is None:
        logger.warning("FreeSolo returned unparseable OBJECTIVE: %r", raw_text[:200])
        objective = {
            "actions": [{"op": "say", "text": "Sorry, I didn't catch that. Try again."}],
            "confidence": 0.0,
        }
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
    elif len(ops) == 1 and ops[0] == "land":
        intent = "land"
    elif len(ops) == 1 and ops[0] == "return":
        intent = "return_to_station"
    elif len(ops) == 1 and ops[0] == "hover":
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
