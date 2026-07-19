"""Gemini-powered disambiguation layer between FreeSolo raw output and drone flight logic.

FreeSolo extracts a ``raw_target`` string from speech transcripts but was not
trained to distinguish between three fundamentally different cases:
  - a physical OBJECT to visually locate  (e.g. "pillar", "red trash can")
  - a lateral DIRECTION                   (e.g. "left", "north", "forward")
  - an ALTITUDE change                    (e.g. "up", "higher", "descend")

This module uses Gemini (gemini-2.5-flash) to classify the raw_target and, in
the seek_object case, also locate the object's bounding box in the provided
camera frame.
"""

import logging
import os
import time
from pathlib import Path
from typing import Literal

from dotenv import load_dotenv
from google import genai
from google.genai import types
from pydantic import BaseModel

from grounding import preprocess_image

load_dotenv(Path(__file__).resolve().parent / ".env")

logger = logging.getLogger(__name__)

_MAX_ATTEMPTS = 2
_MODEL = "gemini-2.5-flash"

_FALLBACK_REASONING = (
    "Gemini unavailable after all retry attempts — defaulting to seek_object/not-found "
    "so downstream code reports 'not found' rather than silently doing nothing."
)


class ActionResolution(BaseModel):
    action_type: Literal["seek_object", "fly_direction", "change_altitude"]
    box_2d: list[int] = []
    """[ymin, xmin, ymax, xmax] normalized 0-1000. Populated only when action_type == 'seek_object'."""
    direction: str = ""
    """Canonical direction word (left/right/forward/backward/north/south/east/west).
    Populated only when action_type == 'fly_direction'."""
    altitude_delta_m: float = 0.0
    """Signed metres: positive = up, negative = down.
    Populated only when action_type == 'change_altitude'."""
    reasoning: str = ""
    """One-sentence explanation of the classification decision, for debugging/demo use."""


_PROMPT_TEMPLATE = """\
You are a drone-command disambiguation assistant. A speech-to-intent model called \
FreeSolo has parsed a voice command and extracted a raw "target" string, but FreeSolo \
was NOT trained to distinguish between three very different cases:

  (a) OBJECT  — a physical thing to visually locate in the camera frame
               (e.g. "pillar", "red trash can", "blue car", "person in jacket")
  (b) DIRECTION — a lateral movement direction
               (e.g. "left", "right", "forward", "backward", "north", "south",
                      "east", "west", "ahead")
  (c) ALTITUDE — a vertical movement instruction
               (e.g. "up", "higher", "down", "lower", "descend", "climb",
                      "go up 3 meters", "rise a bit")

Your task:

1. Examine the attached camera frame AND the inputs below.
2. Classify raw_target into exactly one of: seek_object | fly_direction | change_altitude
3. Fill the corresponding output field:
   - seek_object   → set box_2d to [ymin, xmin, ymax, xmax] (0-1000 normalized) if the
                     object is visible in the frame, or [] if not found.
   - fly_direction → set direction to one canonical word:
                     left | right | forward | backward | north | south | east | west
   - change_altitude → set altitude_delta_m to a signed float (positive = up, negative = down).
                       If the phrase does not specify a distance, use ±1.0 m.
4. Always set reasoning to a single sentence explaining your decision.
5. Leave fields that do not apply at their default empty values ([] / "" / 0.0).

Inputs:
  raw_target  = "{raw_target}"
  raw_intent  = "{raw_intent}"

Respond ONLY with valid JSON matching the ActionResolution schema.
"""


def resolve_action(
    image_bytes: bytes,
    raw_target: str,
    raw_intent: str,
) -> ActionResolution:
    """Classify a FreeSolo raw_target and, for seek_object, locate the bounding box.

    Args:
        image_bytes: Raw bytes of the drone's current camera frame.
        raw_target:  The unclassified target string from FreeSolo's output.
        raw_intent:  The intent string from FreeSolo (e.g. "seek_and_photo").

    Returns:
        ActionResolution with action_type set and the appropriate field populated.
        On total Gemini failure returns a safe fallback (seek_object, box_2d=[]).
    """
    t_start = time.time()
    logger.info(
        "resolve_action | raw_target=%r raw_intent=%r image_bytes=%d",
        raw_target,
        raw_intent,
        len(image_bytes),
    )

    try:
        processed = preprocess_image(image_bytes)
    except ValueError as exc:
        logger.warning("Image preprocessing failed: %s — returning fallback", exc)
        return ActionResolution(
            action_type="seek_object",
            box_2d=[],
            reasoning=f"Image decode failed ({exc}); defaulting to seek_object/not-found.",
        )

    api_key = os.environ.get("GEMINI_API_KEY", "").strip()
    if not api_key:
        logger.warning("GEMINI_API_KEY unset — resolve_action returns fallback")
        return ActionResolution(
            action_type="seek_object",
            box_2d=[],
            reasoning="GEMINI_API_KEY not configured; defaulting to seek_object/not-found.",
        )

    client = genai.Client(api_key=api_key)
    prompt = _PROMPT_TEMPLATE.format(raw_target=raw_target, raw_intent=raw_intent)
    last_exc: Exception | None = None

    for attempt in range(1, _MAX_ATTEMPTS + 1):
        t0 = time.time()
        try:
            response = client.models.generate_content(
                model=_MODEL,
                contents=[
                    types.Part.from_bytes(data=processed, mime_type="image/jpeg"),
                    prompt,
                ],
                config=types.GenerateContentConfig(
                    response_mime_type="application/json",
                    response_schema=ActionResolution,
                ),
            )
            elapsed_ms = (time.time() - t0) * 1000
            result = ActionResolution.model_validate_json(response.text)
            total_ms = (time.time() - t_start) * 1000
            logger.info(
                "resolve_action succeeded | attempt=%d action_type=%s latency=%.0fms "
                "total=%.0fms result=%s",
                attempt,
                result.action_type,
                elapsed_ms,
                total_ms,
                result.model_dump_json(),
            )
            return result
        except Exception as exc:
            elapsed_ms = (time.time() - t0) * 1000
            last_exc = exc
            logger.warning(
                "resolve_action Gemini call failed | attempt=%d latency=%.0fms error=%s",
                attempt,
                elapsed_ms,
                exc,
            )

    total_ms = (time.time() - t_start) * 1000
    logger.error(
        "All %d Gemini attempts failed after %.0fms: %s — returning fallback",
        _MAX_ATTEMPTS,
        total_ms,
        last_exc,
    )
    return ActionResolution(
        action_type="seek_object",
        box_2d=[],
        reasoning=_FALLBACK_REASONING,
    )
