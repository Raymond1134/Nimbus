import io
import logging
import os
import time
from pathlib import Path

from dotenv import load_dotenv
from google import genai
from google.genai import types
from PIL import Image
from pydantic import BaseModel

load_dotenv(Path(__file__).resolve().parent / ".env")

logger = logging.getLogger(__name__)

_MAX_EDGE = 768
_MAX_ATTEMPTS = 2


class GroundingResult(BaseModel):
    found: bool
    box_2d: list[int]   # [ymin, xmin, ymax, xmax], normalized 0–1000; [] when not found
    label: str          # "" when not found
    confidence: float   # 0.0 when not found


_PROMPT_TEMPLATE = (
    "Locate the object matching: '{target}'. "
    "If found, return found=true, box_2d as [ymin, xmin, ymax, xmax] "
    "normalized 0-1000, a short label, and confidence between 0.0 and 1.0. "
    "If not found, return found=false, box_2d=[], label='', confidence=0.0."
)

_FALLBACK = GroundingResult(found=False, box_2d=[], label="", confidence=0.0)


def preprocess_image(image_bytes: bytes) -> bytes:
    """Downscale to max 768px longest edge and convert to JPEG.

    Returns processed JPEG bytes, or raises ValueError if bytes are corrupt/unreadable.
    """
    try:
        img = Image.open(io.BytesIO(image_bytes))
        img.load()  # force decode so corrupt files raise here
    except Exception as exc:
        raise ValueError(f"Cannot decode image: {exc}") from exc

    w, h = img.size
    if max(w, h) > _MAX_EDGE:
        scale = _MAX_EDGE / max(w, h)
        img = img.resize((int(w * scale), int(h * scale)), Image.LANCZOS)

    # JPEG doesn't support alpha; convert to RGB first
    if img.mode not in ("RGB", "L"):
        img = img.convert("RGB")

    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=85)
    return buf.getvalue()


def ground_target(
    image_bytes: bytes,
    target_description: str,
    mime_type: str = "image/jpeg",  # kept for backward-compat; always JPEG after preprocess
) -> GroundingResult:
    try:
        processed = preprocess_image(image_bytes)
    except ValueError as exc:
        logger.warning("Image preprocessing failed: %s", exc)
        return _FALLBACK

    api_key = os.environ.get("GEMINI_API_KEY", "").strip()
    if not api_key:
        logger.warning("GEMINI_API_KEY unset — grounding returns not-found")
        return GroundingResult(found=False, box_2d=[], label="", confidence=0.0)
    client = genai.Client(api_key=api_key)
    last_exc: Exception | None = None

    for attempt in range(1, _MAX_ATTEMPTS + 1):
        t0 = time.time()
        try:
            response = client.models.generate_content(
                model="gemini-flash-latest",
                contents=[
                    types.Part.from_bytes(data=processed, mime_type="image/jpeg"),
                    _PROMPT_TEMPLATE.format(target=target_description),
                ],
                config=types.GenerateContentConfig(
                    response_mime_type="application/json",
                    response_schema=GroundingResult,
                ),
            )
            elapsed_ms = (time.time() - t0) * 1000
            result = GroundingResult.model_validate_json(response.text)
            logger.info(
                "Gemini call succeeded | attempt=%d target=%r found=%s "
                "confidence=%.2f latency=%.0fms",
                attempt,
                target_description,
                result.found,
                result.confidence,
                elapsed_ms,
            )
            return result
        except Exception as exc:
            elapsed_ms = (time.time() - t0) * 1000
            last_exc = exc
            logger.warning(
                "Gemini call failed | attempt=%d latency=%.0fms error=%s",
                attempt,
                elapsed_ms,
                exc,
            )

    logger.error("All %d Gemini attempts failed: %s", _MAX_ATTEMPTS, last_exc)
    return _FALLBACK
