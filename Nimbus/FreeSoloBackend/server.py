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
    
    # 💡 Safety Check: Fallback if ElevenLabs sends back a completely empty string
    text_to_parse = payload.text.strip()
    if not text_to_parse:
        return {"action": "hover", "value": 0, "message": "Empty voice string received"}
    
    try:
        # ✅ FIXED: Pass the string as a direct positional argument to mirror your teammate's infer.py setup
        result = subprocess.run(
            ["python3", "scripts/infer.py", text_to_parse],
            capture_output=True,
            text=True,
            check=True
        )
        
        # Print the raw string data out to your terminal logs for instant hackathon debugging
        print(f"📄 Raw stdout from infer.py:\n{result.stdout}")
        
        # Find and parse the JSON block returned from your Qwen model
        lines = result.stdout.strip().splitlines()
        
        # Grab the very last non-empty line (where the normalized JSON structure prints out)
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
        raise HTTPException(status_code=500, detail=f"Model inference failed: {e.stderr or e.stdout}")
    except Exception as e:
        print(f"❌ Structural mapping error: {str(e)}")
        return {"raw_output": result.stdout.strip() if 'result' in locals() else str(e)}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
