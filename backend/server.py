from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import subprocess
import json
import os

app = FastAPI()

class TranscriptPayload(BaseModel):
    text: str

@app.post("/parse")
async def parse_voice_command(payload: TranscriptPayload):
    print(f"\n📥 Received transcript from iPhone: '{payload.text}'")
    
    # Safety Check: Fallback if ElevenLabs returns an empty string block
    text_to_parse = payload.text.strip()
    if not text_to_parse:
        return {"action": "hover", "value": 0, "message": "Empty voice string received"}
    
    try:
        # ✅ FIXED: Passes text_to_parse as a direct positional argument to prevent infer.py from crashing
        result = subprocess.run(
            ["python3", "scripts/infer.py", text_to_parse],
            capture_output=True,
            text=True,
            check=True
        )
        
        # Print logs out to your terminal for real-time hackathon monitoring
        print(f"📄 Raw stdout from infer.py:\n{result.stdout}")
        
        lines = result.stdout.strip().splitlines()
        last_line = ""
        for line in reversed(lines):
            if line.strip():
                last_line = line.strip()
                break
                
        structured_command = json.loads(last_line)
        print(f"🎯 Model output securely parsed: {structured_command}")
        return structured_command
        
    except subprocess.CalledProcessError as e:
        print(f"❌ Inference error: {e.stderr or e.stdout}")
        
        # 💡 EMERGENCY HACKATHON FALLBACK: If your teammate's cloud models are offline,
        # use a local regex rule engine so your live pitch presentation doesn't freeze!
        print("⚠️ Cloud models offline. Engaging Local Rule Engine Fallback...")
        cmd_lower = text_to_parse.lower()
        if "forward" in cmd_lower:
            return {"action": "move_forward", "meters": 2.0, "status": "success"}
        elif "take off" in cmd_lower or "takeoff" in cmd_lower:
            return {"action": "takeoff", "status": "success"}
        elif "land" in cmd_lower:
            return {"action": "land", "status": "success"}
        else:
            return {"action": "hover", "meters": 0.0, "status": "fallback_active"}
            
    except Exception as e:
        print(f"❌ Structural mapping error: {str(e)}")
        return {"raw_output": result.stdout.strip() if 'result' in locals() else str(e)}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
