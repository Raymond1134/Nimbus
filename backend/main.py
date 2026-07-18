import logging
import time
import traceback

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

app = FastAPI(title="Nimbus Grounding API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


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


if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
