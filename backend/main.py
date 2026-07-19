"""Nimbus v2 Voice Command API.

Pipeline:
  Voice → FreeSolo OBJECTIVE (pipe-delimited 14-op grammar)
  → annotate_steps (Gemini visual grounding)
  → NimbusStep[] (with box_2d per visual target)
  → app implements each op.

FreeSolo (fine-tuned intent model, OpenAI-compatible endpoint) owns
text → OBJECTIVE. The annotator owns vision grounding. The iOS app
owns Virtual Stick execution for each op.
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

app = FastAPI(title="Nimbus v2 API")

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
        return obj(["change_altitude"], 0.85)           # default +0.5 m climb
    if re.search(r"\b(lower|go down|descend|fly down)\b", text) and not target:
        return obj(["change_altitude|-2"], 0.85)        # descend 2 m

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

        try:
            objective = await _get_objective(transcript)
        except HTTPException as exc:
            detail = exc.detail if isinstance(exc.detail, dict) else {"error": str(exc.detail)}
            return JSONResponse(status_code=exc.status_code, content=detail)

        actions = objective.get("actions") or []
        annotated = await annotate_steps(actions, image_bytes)

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
