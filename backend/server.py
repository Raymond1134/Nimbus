from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import subprocess
import json

app = FastAPI()

class TranscriptPayload(BaseModel):
    text: str

@app.post("/parse")
async def parse_voice_command(payload: TranscriptPayload):
    print(f"📥 Received transcript from iPhone: '{payload.text}'")
    
    try:
        # Calls your local fine-tuned Qwen inference script (scripts/infer)
        result = subprocess.run(
            ["python3", "scripts/infer.py", "--text", payload.text],
            capture_output=True,
            text=True,
            check=True
        )
        
        structured_command = json.loads(result.stdout.strip())
        print(f"🤖 Model output: {structured_command}")
        return structured_command
        
    except subprocess.CalledProcessError as e:
        print(f"❌ Inference error: {e.stderr}")
        raise HTTPException(status_code=500, detail=f"Model inference failed: {e.stderr}")
    except json.JSONDecodeError:
        return {"raw_output": result.stdout.strip()}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
