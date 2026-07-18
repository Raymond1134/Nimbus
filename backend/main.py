import uvicorn
from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, UploadFile
from fastapi.middleware.cors import CORSMiddleware

from grounding import GroundingResult, ground_target

load_dotenv()

app = FastAPI(title="Nimbus Grounding API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.post("/ground_target", response_model=GroundingResult)
async def ground_target_route(
    image: UploadFile = File(...),
    target_description: str = Form(...),
) -> GroundingResult:
    image_bytes = await image.read()
    mime_type = image.content_type or "image/jpeg"
    return ground_target(image_bytes, target_description, mime_type)


if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
