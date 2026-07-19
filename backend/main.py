from __future__ import annotations

"""Nimbus Voice Command API.

Pipeline:
  Voice → FreeSolo → OBJECTIVE JSON (complete mission steps)
       → if visual ops present → Gemini: fetch box_2d per target
       → merge box_2d into OBJECTIVE actions
       → NimbusStep[] → iOS app executes each op via Virtual Stick

FreeSolo is the sole mission planner. Gemini is only called when
fly_to|<target>, orbit|<target>, or look_at|<target> steps are present,
and it returns bounding boxes only. Non-visual commands never touch Gemini.
"""

import logging
import os
import re
import traceback
from pathlib import Path
from typing import Any

import httpx
import uvicorn
from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from annotator import annotate_steps
from objective import (
    SYSTEM_PROMPT,
    make_objective,
    normalize_objective,
    parse_and_normalize,
)
from resolve_action import ActionResolution, resolve_action

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
_FREESOLO_TIMEOUT = 6.0   # fail fast to mock on slow Modal cold-starts
_freesolo_configured = bool(_FREESOLO_BASE_URL and _FREESOLO_API_KEY and _FREESOLO_MODEL)
_USE_MOCK = os.getenv(
    "USE_FREESOLO_MOCK",
    "false" if _freesolo_configured else "true",
).lower() == "true"

app = FastAPI(title="Nimbus v2 API")


@app.on_event("startup")
async def _warm_up_freesolo() -> None:
    """Ping FreeSolo on startup so the Modal container is warm for the
    first real voice command, eliminating cold-start latency (~1-2 s)."""
    if _USE_MOCK:
        return
    import asyncio
    async def _ping() -> None:
        try:
            await _get_objective("takeoff")
            logger.info("FreeSolo warm-up OK")
        except Exception as exc:
            logger.warning("FreeSolo warm-up failed (will retry on first request): %s", exc)
    asyncio.ensure_future(_ping())


app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------------------------------------------------------------------------
# FreeSolo helpers — returns OBJECTIVE {steps, actions, confidence}
# ---------------------------------------------------------------------------

_TARGET_TRIGGERS = (
    "fly to", "go to", "head to", "find", "approach", "fly towards", "fly toward",
    "orbit", "circle", "fly around", "look at", "point the camera at", "aim at",
    "follow", "track", "picture of", "photo of", "shot of", "photograph",
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
    if re.search(r"\b(take ?off|lift ?off|launch|liftoff|air ?borne)\b", text):
        return obj(["takeoff"], 0.95)
    if re.search(r"\bland\b", text) and "fly" not in text and "launch" not in text:
        return obj(["land"], 0.95)
    if re.search(r"\b(return|come back|fly back|come home|fly home)\b", text) and not target:
        return obj(["return"], 0.9)
    if re.search(r"\bselfie|picture of me|photo of me|dronie\b", text):
        return obj(["selfie"], 0.9)
    if re.search(r"\b(panorama|pano|360 photo)\b", text):
        return obj(["panorama"], 0.9)
    if re.search(r"\b(hover|hold position|stay put|hold station)\b", text) and not target:
        return obj(["hover"], 0.9)
    if re.search(r"\b(higher|go up|climb|fly up|ascend|rise)\b", text) and not target:
        return obj(["change_altitude"], 0.85)           # bare = +0.5 m climb
    if re.search(r"\b(lower|go down|descend|fly down|drop)\b", text) and not target:
        return obj(["change_altitude|-0.5"], 0.85)      # bare = -0.5 m descend

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

    if isinstance(data.get("steps"), list):
        normalized = normalize_objective(data, lenient=True)
        if normalized is not None:
            return normalized
        logger.warning("Invalid steps in OBJECTIVE payload: %s", data.get("steps"))

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
        "max_tokens": 64,   # OBJECTIVE JSON is ~30-50 tokens; 64 is plenty
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


async def _read_image(image: UploadFile) -> bytes:
    content_type = image.content_type or ""
    if not content_type.startswith("image/"):
        raise HTTPException(
            status_code=400,
            detail="File must be an image (image/* content type required).",
        )
    image_bytes = await image.read()
    if len(image_bytes) > _MAX_BYTES:
        raise HTTPException(status_code=413, detail="Image too large. Maximum size is 10 MB.")
    return image_bytes


# ---------------------------------------------------------------------------
# NimbusStep builder
# ---------------------------------------------------------------------------

def _action_to_nimbus_step(action: dict[str, Any]) -> dict[str, Any]:
    """Convert an annotated action dict to a NimbusStep dict."""
    op = action.get("op", "")
    yaw_deg = action.get("yaw_deg")
    return {
        "op": op,
        "target": action.get("target"),
        "box_2d": action.get("box_2d", []),
        "found": action.get("found", False),
        "distance_m": action.get("distance_m"),
        "confidence": action.get("confidence", 0.0),
        "delta_m": action.get("delta_m"),
        "direction": action.get("direction"),
        "degrees": abs(yaw_deg) if yaw_deg is not None else None,
        "revolutions": action.get("revolutions"),
        "seconds": action.get("duration_s"),
        "text": action.get("text"),
    }


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get("/health")
async def health() -> dict:
    return {
        "status": "ok",
        "mode": "mock" if _USE_MOCK else "live",
        "gemini_configured": bool(os.getenv("GEMINI_API_KEY", "").strip()),
        "freesolo_configured": bool(_FREESOLO_BASE_URL and _FREESOLO_API_KEY and _FREESOLO_MODEL),
    }


@app.post("/resolve_action", response_model=ActionResolution)
async def resolve_action_route(
    image: UploadFile = File(...),
    target: str = Form(...),
    intent: str = Form(...),
) -> JSONResponse:
    """Classify a FreeSolo raw_target into seek_object / fly_direction / change_altitude.

    Uses Gemini (gemini-2.5-flash) to disambiguate the target string and, for
    seek_object, locate the bounding box in the provided camera frame.

    Form fields:
      image  — drone camera frame (image/*)
      target — raw target string from FreeSolo (e.g. "left", "pillar", "up")
      intent — raw intent string from FreeSolo (e.g. "seek_and_photo")

    Returns ActionResolution JSON.
    """
    try:
        image_bytes = await _read_image(image)
        logger.info(
            "resolve_action_route | target=%r intent=%r image_bytes=%d",
            target,
            intent,
            len(image_bytes),
        )
        result = resolve_action(image_bytes, target, intent)
        return JSONResponse(content=result.model_dump())
    except HTTPException:
        raise
    except Exception:
        logger.error("Unhandled error in /resolve_action:\n%s", traceback.format_exc())
        return JSONResponse(
            status_code=500,
            content={"error": "Internal server error", "detail": traceback.format_exc()},
        )


@app.post("/voice_command")
async def voice_command_route(
    transcript: str = Form(...),
    image: UploadFile = File(...),
) -> JSONResponse:
    """Full pipeline: transcript → FreeSolo OBJECTIVE → Gemini annotation → NimbusSteps.

    Response:
      {
        "steps": [NimbusStep, ...],
        "confidence": float,
        "transcript": str
      }
    """
    try:
        image_bytes = await _read_image(image)

        logger.info(
            "voice_command | mode=%s transcript=%r",
            "MOCK" if _USE_MOCK else "LIVE",
            transcript,
        )

        # Use transcript keyword heuristic (instant) to predict the likely
        # visual target BEFORE FreeSolo responds. If the prediction matches
        # FreeSolo's output, we save the full Gemini round-trip time (~900 ms)
        # because resolve_action ran in parallel with FreeSolo.
        import asyncio
        from resolve_action import resolve_action as _resolve_action

        predicted_target = _extract_target_phrase(transcript)
        gemini_api_key = os.getenv("GEMINI_API_KEY", "").strip()

        if predicted_target and gemini_api_key:
            async def _pre_resolve() -> Any:
                try:
                    return await asyncio.to_thread(
                        _resolve_action, image_bytes, predicted_target, "fly_to"
                    )
                except Exception as exc:
                    logger.warning("Pre-resolution failed for %r: %s", predicted_target, exc)
                    return None

            try:
                objective, pre_result = await asyncio.gather(
                    _get_objective(transcript),
                    _pre_resolve(),
                )
            except HTTPException as exc:
                detail = exc.detail if isinstance(exc.detail, dict) else {"error": str(exc.detail)}
                return JSONResponse(status_code=exc.status_code, content=detail)

            resolution_cache = (
                {predicted_target.lower(): pre_result} if pre_result is not None else {}
            )
            if pre_result is not None:
                logger.info(
                    "parallel pre-resolution done | target=%r action_type=%s",
                    predicted_target, pre_result.action_type,
                )
        else:
            try:
                objective = await _get_objective(transcript)
            except HTTPException as exc:
                detail = exc.detail if isinstance(exc.detail, dict) else {"error": str(exc.detail)}
                return JSONResponse(status_code=exc.status_code, content=detail)
            resolution_cache: dict[str, Any] = {}

        actions = objective.get("actions") or []
        annotated = await annotate_steps(actions, image_bytes, resolution_cache=resolution_cache)

        steps = [_action_to_nimbus_step(a) for a in annotated]
        confidence = float(objective.get("confidence", 0.0))

        logger.info(
            "voice_command done | steps=%d confidence=%.2f",
            len(steps),
            confidence,
        )

        return JSONResponse(content={
            "steps": steps,
            "confidence": confidence,
            "transcript": transcript,
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
