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
# FreeSolo helpers
# ---------------------------------------------------------------------------

# Words that introduce a target noun phrase in spoken drone commands.
_TRIGGER_WORDS = (
    "find", "locate", "photograph", "photo of", "picture of",
    "look for", "search for", "go to", "fly to", "move to",
    "towards", "toward", "at", "to", "the",
)
# Low-information words to strip from the extracted phrase, including pronouns
# so that "photograph it" doesn't yield "it" as the target.
_FILLER = frozenset({
    "a", "an", "the", "me", "please", "some", "that", "this",
    "it", "them", "they", "him", "her", "us", "one",
})


def _mock_freesolo_intent(transcript: str) -> dict:
    """Extract a target noun phrase from *transcript* via simple keyword rules.

    Scans for the first content word(s) that follow a trigger phrase.
    Falls back to "object" if nothing useful is found.
    """
    text = transcript.lower().strip()

    # Try multi-word triggers first (longest match wins), then single words.
    for trigger in sorted(_TRIGGER_WORDS, key=len, reverse=True):
        pattern = rf"\b{re.escape(trigger)}\s+(.+)"
        m = re.search(pattern, text)
        if m:
            remainder = m.group(1).split()
            # Drop leading filler words, then take up to 3 content words.
            content = [w for w in remainder if w not in _FILLER]
            if content:
                # Stop at clause boundaries (conjunctions / prepositions).
                stop = {"and", "or", "but", "near", "by", "with", "in", "on", "of"}
                phrase_words = []
                for w in content:
                    if w in stop:
                        break
                    phrase_words.append(w)
                if phrase_words:
                    target = " ".join(phrase_words[:3])
                    return {
                        "intent": "seek_and_photo",
                        "target": target,
                        "say_text": None,
                        "constraints": {"max_seconds": 45.0, "max_radius_m": 30.0},
                        "confidence": 0.9,
                    }

    return {
        "intent": "seek_and_photo",
        "target": "object",
        "say_text": None,
        "constraints": {"max_seconds": 45.0, "max_radius_m": 30.0},
        "confidence": 0.9,
    }


async def _call_freesolo_real(transcript: str) -> dict:
    """POST transcript to the live FreeSolo endpoint and return the intent dict.

    Raises httpx exceptions on connection/timeout/HTTP errors — caller handles them.
    """
    async with httpx.AsyncClient(timeout=_FREESOLO_TIMEOUT) as client:
        resp = await client.post(_FREESOLO_URL, json={"transcript": transcript})
        resp.raise_for_status()
        return resp.json()


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
        # --- validation ---
        content_type = image.content_type or ""
        if not content_type.startswith("image/"):
            raise HTTPException(status_code=400, detail="File must be an image (image/* content type required).")

        if not target_description.strip():
            raise HTTPException(status_code=400, detail="target_description must not be empty.")

        image_bytes = await image.read()

        if len(image_bytes) > _MAX_BYTES:
            raise HTTPException(status_code=413, detail="Image too large. Maximum size is 10 MB.")

        # --- call grounding ---
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


@app.post("/voice_command")
async def voice_command_route(
    transcript: str = Form(...),
    image: UploadFile = File(...),
) -> JSONResponse:
    try:
        # --- image validation (same rules as /ground_target) ---
        content_type = image.content_type or ""
        if not content_type.startswith("image/"):
            raise HTTPException(status_code=400, detail="File must be an image (image/* content type required).")

        image_bytes = await image.read()

        if len(image_bytes) > _MAX_BYTES:
            raise HTTPException(status_code=413, detail="Image too large. Maximum size is 10 MB.")

        logger.info(
            "voice_command | mode=%s transcript=%r",
            "MOCK" if _USE_MOCK else "LIVE",
            transcript,
        )

        # --- get intent (mock or real) ---
        if _USE_MOCK:
            intent_data = _mock_freesolo_intent(transcript)
            logger.info(
                "[MOCK] FreeSolo call skipped, using local extraction | target=%r",
                intent_data["target"],
            )
        else:
            try:
                intent_data = await _call_freesolo_real(transcript)
            except (httpx.ConnectError, httpx.TimeoutException) as exc:
                logger.warning("FreeSolo service unreachable: %s", exc)
                return JSONResponse(
                    status_code=502,
                    content={"error": "FreeSolo service unreachable", "detail": str(exc)},
                )
            except httpx.HTTPStatusError as exc:
                logger.warning("FreeSolo returned HTTP %d: %s", exc.response.status_code, exc)
                return JSONResponse(
                    status_code=502,
                    content={
                        "error": "FreeSolo service returned an error",
                        "detail": str(exc),
                        "freesolo_status": exc.response.status_code,
                    },
                )

        logger.info("Intent from FreeSolo: %s", intent_data)

        # --- extract target and run grounding ---
        target = (intent_data.get("target") or "").strip() or "object"

        t0 = time.time()
        grounding_result = ground_target(image_bytes, target, content_type)
        elapsed_ms = (time.time() - t0) * 1000

        logger.info(
            "Grounding complete | target=%r found=%s grounding_confidence=%.2f latency=%.0fms",
            target,
            grounding_result.found,
            grounding_result.confidence,
            elapsed_ms,
        )

        # --- build combined response ---
        return JSONResponse(content={
            "intent":               intent_data.get("intent"),
            "target":               intent_data.get("target"),
            "say_text":             intent_data.get("say_text"),
            "constraints":          intent_data.get("constraints"),
            "confidence":           intent_data.get("confidence"),
            "found":                grounding_result.found,
            "box_2d":               grounding_result.box_2d,
            "label":                grounding_result.label,
            "grounding_confidence": grounding_result.confidence,
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
