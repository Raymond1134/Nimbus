# FreeSolo Intent Model (text → OBJECTIVE JSON)

This folder owns stage 1 of the Nimbus command pipeline:

```
voice → ElevenLabs STT → [FreeSolo fine-tuned model] → OBJECTIVE JSON
      → backend /voice_command (Gemini + drone frame)  → InstructionStep[] (with box_2d)
      → iOS app executes each op on Virtual Stick
```

## OBJECTIVE contract

The model emits exactly:

```json
{"steps":["fly_to|red tent","photo","rotate|right|360","return"],"confidence":0.95}
```

Steps are flat pipe-strings (easy for a small SFT model to emit reliably).
`objective.py` is the single source of truth for the grammar, parser
(`parse_and_normalize` → structured `actions` dicts), and SFT reward
(`score_objectives`). `backend/objective.py` is a vendored copy — keep in sync.

Ops (1:1 with the planner's InstructionStep ops):
`takeoff, land, fly_to|t, fly_higher|m?, fly_lower|m?, fly_above|t,
rotate|left/right|deg?, orbit|t|revs?, hover|s?, look_at|t, photo, selfie,
panorama, follow|t|s?, return, abort, say|text`

## Files

- `environment.py` — FreeSolo `EnvironmentSingleTurn` (dataset + prompt + reward)
- `objective.py` — grammar, parser, scorer, system prompt
- `system_prompt.txt` — same prompt as a file (for served calls)
- `scripts/generate_dataset.py` — synthetic transcript→objective data (ASR noise, compounds)
- `scripts/make_smoke_dataset.py` — tiny gold split for cheap format-check runs
- `scripts/infer.py` — call the deployed adapter (`--repl`, `--eval dataset/eval.jsonl`)
- `configs/{smoke,sft,rl}.toml` — Flash training configs
- `test_objective.py` — grammar unit tests (`python -m pytest test_objective.py`)

## Training workflow (flash CLI — run from WSL; the CLI is not Windows-native)

```bash
cd /mnt/d/projects/nimbus/Nimbus/FreeSoloBackend
python scripts/generate_dataset.py --count 12000 --eval-count 800
python scripts/make_smoke_dataset.py
flash env push --name voice-drone-objective .
flash train configs/smoke.toml --dry-run     # server-side validation, free
flash train configs/smoke.toml --cost        # price preview, free
flash train configs/smoke.toml               # ~$0.09 format check
flash train configs/sft.toml                 # main run
flash deploy <run-id>
flash chat <run-id> -m "fly to the tree and take a picture"
```

Runs so far:
- `flash-1784395386-5c250929` — smoke (new grammar), done + deployed + verified
- `flash-1784396024-91cbb2f2` — main SFT, 12k examples / 250 steps

## Using the deployed model

Set in `.env` (this folder) and in `backend/.env`:

```
FREESOLO_API_KEY=fslo_...
FREESOLO_BASE_URL=https://clado-ai--freesolo-lora-serving.modal.run/v1
FREESOLO_MODEL=<deployed run id>
```

Then either call it directly (`python scripts/infer.py "..."`), or set
`USE_FREESOLO_MOCK=false` for `backend/main.py` so `/voice_command` uses the
real model. Evaluate quality with:

```bash
python scripts/infer.py --eval dataset/eval.jsonl --limit 100
```
