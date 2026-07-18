from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import subprocess
import json
import os

app = FastAPI(title="Nimbus E2E Bridging Core")

class TranscriptPayload(BaseModel):
    text: str

@app.post("/parse")
async def parse_voice_command(payload: TranscriptPayload):
    print(f"\n📥 Received transcript from iPhone: '{payload.text}'")
    
    text_to_parse = payload.text.strip()
    if not text_to_parse:
        return {"ok": False, "message": "Empty voice string received"}
    
    try:
        # ✅ CALL THE MASTER PIPELINE: Pass the transcript cleanly into the master orchestration script
        result = subprocess.run(
            ["python3", "e2e_pipeline.py", text_to_parse],
            capture_output=True,
            text=True,
            check=True
        )
        
        # Split output lines to find our structural telemetry headers
        lines = result.stdout.strip().splitlines()
        print(f"📄 Raw stdout from pipeline loop:\n{result.stdout}")
        
        # Grab the very last non-empty line where the execution metadata json prints out
        last_line = ""
        for line in reversed(lines):
            if line.strip():
                last_line = line.strip()
                break
                
        structured_response = json.loads(last_line)
        print(f"🎯 Core pipeline sequence executed successfully: {structured_response}")
        return structured_response
        
    except subprocess.CalledProcessError as e:
        print(f"❌ Pipeline runtime script error: {e.stderr or e.stdout}")
        
        # Emergency hackathon fallback if your cloud fine-tuning instances drop offline mid-pitch
        print("⚠️ Cloud fine-tuning environment down. Engaging Local Structural Fallback...")
        cmd_lower = text_to_parse.lower()
        if "forward" in cmd_lower or "straight" in cmd_lower:
            return {"ok": True, "planner": "skeleton", "steps": 3, "fallback_active": True}
        else:
            return {"ok": True, "planner": "skeleton", "steps": 1, "fallback_active": True}
            
    except Exception as e:
        print(f"❌ Structural mapping error: {str(e)}")
        return {"ok": False, "error": str(e)}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
