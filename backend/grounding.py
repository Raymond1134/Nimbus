import os

from dotenv import load_dotenv
from google import genai
from google.genai import types
from pydantic import BaseModel

load_dotenv()


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


def ground_target(
    image_bytes: bytes,
    target_description: str,
    mime_type: str = "image/jpeg",
) -> GroundingResult:
    client = genai.Client(api_key=os.environ["GEMINI_API_KEY"])
    try:
        response = client.models.generate_content(
            model="gemini-flash-latest",
            contents=[
                types.Part.from_bytes(data=image_bytes, mime_type=mime_type),
                _PROMPT_TEMPLATE.format(target=target_description),
            ],
            config=types.GenerateContentConfig(
                response_mime_type="application/json",
                response_schema=GroundingResult,
            ),
        )
        return GroundingResult.model_validate_json(response.text)
    except Exception:
        return GroundingResult(found=False, box_2d=[], label="", confidence=0.0)
