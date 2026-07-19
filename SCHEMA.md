# Nimbus v2 — Schema Reference

Complete contract between FreeSolo, the Python backend, and the iOS app.
Use this when fine-tuning the model, debugging the backend, or implementing iOS op dispatch.

---

## Pipeline Overview

```
Voice
  → ElevenLabs STT  →  transcript: str
  → FreeSolo model  →  OBJECTIVE JSON  (14 strict ops, pipe-delimited)
  → backend/annotator.py + Gemini Flash  →  visual annotation (box_2d, distance_m)
  → POST /voice_command response  →  NimbusResponse JSON
  → iOS MissionExecutor  →  DJI Virtual Stick
```

---

## 1. FreeSolo OBJECTIVE JSON

FreeSolo outputs this directly. The backend parses and annotates it.

```json
{
  "steps": ["op", "op|arg", "op|arg|arg2"],
  "confidence": 0.95
}
```

- `steps`: ordered array of pipe-delimited step strings
- `confidence`: float 0.0–1.0, model's certainty in the full plan

### Step Grammar

| Step string | Fields produced |
|---|---|
| `takeoff` | op |
| `land` | op |
| `fly_to\|<target>` | op, target (visual object or place) |
| `fly_to\|forward\|<meters>` | op, direction="forward", distance_m (0.5 if omitted) |
| `fly_to\|back\|<meters>` | op, direction="back", distance_m |
| `fly_to\|left\|<meters>` | op, direction="left", distance_m |
| `fly_to\|right\|<meters>` | op, direction="right", distance_m |
| `change_altitude\|<+/-meters>` | op, delta_m (positive=up, negative=down; ±0.5 if omitted) |
| `rotate\|left\|<degrees>` | op, direction="left", yaw_deg (−90 if omitted) |
| `rotate\|right\|<degrees>` | op, direction="right", yaw_deg (+90 if omitted) |
| `orbit\|<target>\|<revolutions>` | op, target, revolutions (1.0 if omitted) |
| `hover\|<seconds>` | op, duration_s (5.0 if omitted) |
| `look_at\|<target>` | op, target |
| `photo` | op |
| `selfie` | op |
| `panorama` | op |
| `follow\|<target>\|<seconds>` | op, target, duration_s (30.0 if omitted) |
| `return` | op |
| `abort` | op |
| `say\|<text>` | op, text |

### Default Values

| Op | Field | Default |
|---|---|---|
| `fly_to` (relative) | distance_m | **0.5 m** (~1.5 ft) |
| `change_altitude` | delta_m | **±0.5 m** |
| `rotate` | yaw_deg | **±90°** |
| `orbit` | revolutions | **1** |
| `hover` | duration_s | **5 s** |
| `follow` | duration_s | **30 s** |

### Op Aliases (lenient / inference mode only)

The backend maps near-miss op names onto valid ops at inference time.
These aliases are **never used for training rewards** — the model is trained on the exact 14 ops above.

| Alias | Resolves to |
|---|---|
| `fly_higher`, `fly_up`, `ascend`, `climb` | `change_altitude` (positive delta) |
| `fly_lower`, `fly_down`, `descend` | `change_altitude` (negative delta) |
| `fly_forward`, `move_forward`, `go_forward` | `fly_to\|forward` |
| `fly_backward`, `fly_back`, `move_back`, `go_backward` | `fly_to\|back` |
| `fly_left`, `move_left`, `strafe_left`, `go_left` | `fly_to\|left` |
| `fly_right`, `move_right`, `strafe_right`, `go_right` | `fly_to\|right` |
| `fly_behind`, `fly_past`, `fly_toward`, `go_to`, `approach` | `fly_to` (visual) |
| `spin`, `turn`, `yaw` | `rotate` |
| `circle` | `orbit` |
| `look`, `point_at`, `aim`, `watch`, `gimbal` | `look_at` |
| `take_photo`, `take_picture`, `picture`, `snap` | `photo` |
| `dronie` | `selfie` |
| `pano` | `panorama` |
| `track` | `follow` |
| `take_off`, `launch` | `takeoff` |
| `come_back`, `fly_home`, `return_home`, `go_home`, `rth` | `return` |
| `stop`, `cancel`, `halt` | `abort` |
| `wait`, `hold`, `hover_station` | `hover` |

### Examples

```json
{"steps":["fly_to|red tent","photo","rotate|right|360","return"],"confidence":0.95}
{"steps":["takeoff","follow|me|30"],"confidence":0.92}
{"steps":["fly_to|forward","change_altitude|-1"],"confidence":0.88}
{"steps":["orbit|fountain|2","panorama"],"confidence":0.90}
{"steps":["say|I only handle flight commands."],"confidence":0.50}
```

---

## 2. Gemini Annotation

Gemini Flash receives the drone camera frame and a list of visual targets.
It annotates only ops with a **real visual target** (not direction words):
- `fly_to` (when target is a place/object, not "forward"/"back"/"left"/"right")
- `orbit`
- `look_at`
- `follow`

One Gemini call covers all visual steps in the objective at once.

### Gemini Input
- Image: current drone camera frame (JPEG, resized to ≤1024px)
- Targets: list of target strings from visual steps

### Gemini Output (per target)

```json
{
  "annotations": [
    {
      "target": "red tent",
      "found": true,
      "box_2d": [120, 340, 580, 720],
      "distance_m": 8.5,
      "confidence": 0.93
    },
    {
      "target": "fountain",
      "found": false,
      "box_2d": [],
      "distance_m": null,
      "confidence": 0.0
    }
  ]
}
```

- `box_2d`: `[ymin, xmin, ymax, xmax]` normalized 0–1000 (top-left origin). Empty `[]` if not found.
- `distance_m`: estimated distance from drone to target in meters. `null` if not found or unclear.
- `confidence`: Gemini's annotation confidence 0.0–1.0.

---

## 3. NimbusResponse — Backend → iOS

`POST /voice_command` returns this JSON.

```json
{
  "steps": [ ...NimbusStep... ],
  "confidence": 0.95,
  "transcript": "fly to the red tent and take a picture"
}
```

### NimbusStep — Full Field Reference

Every step always has all fields present (null for unused ones).

| Field | Type | Description |
|---|---|---|
| `op` | string | Instruction name (see ops below) |
| `target` | string? | Visual target name (fly_to/orbit/look_at/follow) |
| `box_2d` | [int] | `[ymin,xmin,ymax,xmax]` 0–1000; `[]` if not found/not visual |
| `found` | bool | True if Gemini located the target in the frame |
| `distance_m` | float? | Gemini distance estimate in meters; null if not visual |
| `confidence` | float | Gemini annotation confidence 0–1; 0.0 for non-visual ops |
| `delta_m` | float? | `change_altitude` only: signed meters (+up / −down) |
| `direction` | string? | `rotate`: "left"\|"right"; `fly_to` relative: "forward"\|"back"\|"left"\|"right" |
| `degrees` | float? | `rotate` only |
| `revolutions` | float? | `orbit` only |
| `seconds` | float? | `hover` or `follow` duration |
| `text` | string? | `say` reply text |

### NimbusStep Examples — One Per Op

**takeoff**
```json
{"op":"takeoff","target":null,"box_2d":[],"found":false,"distance_m":null,"confidence":0.0,"delta_m":null,"direction":null,"degrees":null,"revolutions":null,"seconds":null,"text":null}
```

**land**
```json
{"op":"land","target":null,"box_2d":[],"found":false,"distance_m":null,"confidence":0.0,"delta_m":null,"direction":null,"degrees":null,"revolutions":null,"seconds":null,"text":null}
```

**fly_to (visual approach)**
```json
{"op":"fly_to","target":"red tent","box_2d":[120,340,580,720],"found":true,"distance_m":8.5,"confidence":0.93,"delta_m":null,"direction":null,"degrees":null,"revolutions":null,"seconds":null,"text":null}
```

**fly_to (relative nudge — forward 2 m)**
```json
{"op":"fly_to","target":null,"box_2d":[],"found":false,"distance_m":2.0,"confidence":0.0,"delta_m":null,"direction":"forward","degrees":null,"revolutions":null,"seconds":null,"text":null}
```

**fly_to (relative nudge — backward, no distance → 0.5 m default)**
```json
{"op":"fly_to","target":null,"box_2d":[],"found":false,"distance_m":null,"confidence":0.0,"delta_m":null,"direction":"back","degrees":null,"revolutions":null,"seconds":null,"text":null}
```

**change_altitude (climb 1.5 m)**
```json
{"op":"change_altitude","target":null,"box_2d":[],"found":false,"distance_m":null,"confidence":0.0,"delta_m":1.5,"direction":null,"degrees":null,"revolutions":null,"seconds":null,"text":null}
```

**change_altitude (descend, no value → −0.5 m default)**
```json
{"op":"change_altitude","target":null,"box_2d":[],"found":false,"distance_m":null,"confidence":0.0,"delta_m":-0.5,"direction":null,"degrees":null,"revolutions":null,"seconds":null,"text":null}
```

**rotate (right 90°)**
```json
{"op":"rotate","target":null,"box_2d":[],"found":false,"distance_m":null,"confidence":0.0,"delta_m":null,"direction":"right","degrees":90.0,"revolutions":null,"seconds":null,"text":null}
```

**rotate (spin 360°)**
```json
{"op":"rotate","target":null,"box_2d":[],"found":false,"distance_m":null,"confidence":0.0,"delta_m":null,"direction":"right","degrees":360.0,"revolutions":null,"seconds":null,"text":null}
```

**orbit (2 revolutions around fountain)**
```json
{"op":"orbit","target":"fountain","box_2d":[200,400,700,800],"found":true,"distance_m":6.0,"confidence":0.87,"delta_m":null,"direction":null,"degrees":null,"revolutions":2.0,"seconds":null,"text":null}
```

**hover (10 s)**
```json
{"op":"hover","target":null,"box_2d":[],"found":false,"distance_m":null,"confidence":0.0,"delta_m":null,"direction":null,"degrees":null,"revolutions":null,"seconds":10.0,"text":null}
```

**look_at**
```json
{"op":"look_at","target":"dog","box_2d":[300,200,600,700],"found":true,"distance_m":4.0,"confidence":0.81,"delta_m":null,"direction":null,"degrees":null,"revolutions":null,"seconds":null,"text":null}
```

**photo**
```json
{"op":"photo","target":null,"box_2d":[],"found":false,"distance_m":null,"confidence":0.0,"delta_m":null,"direction":null,"degrees":null,"revolutions":null,"seconds":null,"text":null}
```

**selfie**
```json
{"op":"selfie","target":null,"box_2d":[],"found":false,"distance_m":null,"confidence":0.0,"delta_m":null,"direction":null,"degrees":null,"revolutions":null,"seconds":null,"text":null}
```

**panorama**
```json
{"op":"panorama","target":null,"box_2d":[],"found":false,"distance_m":null,"confidence":0.0,"delta_m":null,"direction":null,"degrees":null,"revolutions":null,"seconds":null,"text":null}
```

**follow (30 s, target in frame)**
```json
{"op":"follow","target":"person in the red jacket","box_2d":[150,300,800,650],"found":true,"distance_m":5.0,"confidence":0.88,"delta_m":null,"direction":null,"degrees":null,"revolutions":null,"seconds":30.0,"text":null}
```

**return**
```json
{"op":"return","target":null,"box_2d":[],"found":false,"distance_m":null,"confidence":0.0,"delta_m":null,"direction":null,"degrees":null,"revolutions":null,"seconds":null,"text":null}
```

**abort**
```json
{"op":"abort","target":null,"box_2d":[],"found":false,"distance_m":null,"confidence":0.0,"delta_m":null,"direction":null,"degrees":null,"revolutions":null,"seconds":null,"text":null}
```

**say**
```json
{"op":"say","target":null,"box_2d":[],"found":false,"distance_m":null,"confidence":0.0,"delta_m":null,"direction":null,"degrees":null,"revolutions":null,"seconds":null,"text":"I only handle flight commands."}
```

### Per-op field matrix

Which NimbusStep fields are populated (non-null / non-empty) for each op:

| op | target | box_2d | found | distance_m | confidence | delta_m | direction | degrees | revolutions | seconds | text |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `takeoff` | — | — | — | — | — | — | — | — | — | — | — |
| `land` | — | — | — | — | — | — | — | — | — | — | — |
| `fly_to` (visual) | ✓ | ✓ | ✓ | ✓ | ✓ | — | — | — | — | — | — |
| `fly_to` (relative) | — | — | — | opt | — | — | ✓ | — | — | — | — |
| `change_altitude` | — | — | — | — | — | ✓ | — | — | — | — | — |
| `rotate` | — | — | — | — | — | — | ✓ | ✓ | — | — | — |
| `orbit` | ✓ | ✓ | ✓ | ✓ | ✓ | — | — | — | ✓ | — | — |
| `hover` | — | — | — | — | — | — | — | — | — | ✓ | — |
| `look_at` | ✓ | ✓ | ✓ | ✓ | ✓ | — | — | — | — | — | — |
| `photo` | — | — | — | — | — | — | — | — | — | — | — |
| `selfie` | — | — | — | — | — | — | — | — | — | — | — |
| `panorama` | — | — | — | — | — | — | — | — | — | — | — |
| `follow` | ✓ | ✓ | ✓ | ✓ | ✓ | — | — | — | — | ✓ | — |
| `return` | — | — | — | — | — | — | — | — | — | — | — |
| `abort` | — | — | — | — | — | — | — | — | — | — | — |
| `say` | — | — | — | — | — | — | — | — | — | — | ✓ |

`✓` = always populated · `opt` = present only if model specified a distance · `—` = always null/empty/false

---

## 4. iOS MissionExecutor Dispatch

How each op is implemented in `MissionExecutor.swift`:

| Op | Implementation |
|---|---|
| `takeoff` | `bridge.takeOff()` → wait until flying (12 s timeout) |
| `land` | `behaviors.stop()` → `bridge.startLanding()` |
| `fly_to` (visual, found) | `behaviors.approach(box: box2d, standoffM: distanceM*0.3 ?? 3.0, maxSeconds: 40)` |
| `fly_to` (visual, not found) | `say("I can't see <target>.")` — does not fail mission |
| `fly_to` (relative nudge) | `timedVelocity` at 0.8 m/s for `distanceM ?? 0.5` seconds; forward→pitch+, back→pitch−, left→roll−, right→roll+  |
| `change_altitude` | `behaviors.changeAltitude(deltaM: deltaM ?? ±0.5)` |
| `rotate` | `behaviors.rotateBy(yawDeg: degrees ?? 90, signed by direction)` |
| `orbit` | `behaviors.approach(box:, standoffM:3)` if found, then `behaviors.orbit(radiusM:5, durationSec: revolutions*18)` |
| `hover` | `behaviors.stop()` → `Task.sleep(seconds ?? 5)` |
| `look_at` | `pointGimbalAt(box:)` if found, else `bridge.pointGimbal(pitchDeg: -30)` |
| `photo` | `behaviors.stop()` → 0.6 s settle → `bridge.capturePhoto()` |
| `selfie` | Aim gimbal, timedVelocity backward+climb 3 s, re-aim, capturePhoto |
| `panorama` | 4 × (capturePhoto → rotateBy(90°)) |
| `follow` | `behaviors.followPerson(maxSeconds: seconds ?? 30, overheadMode: false, seedBox:)` |
| `return` | `behaviors.followPerson(maxSeconds: 60, overheadMode: true)` |
| `abort` | `behaviors.stop()` → `onAbortRequested?()` → Orchestrator calls `resumeOverheadHold()` |
| `say` | `speak(text)` |

### iOS Swift decoding — CodingKeys

`NimbusStep` uses custom `CodingKeys` to bridge snake_case JSON → camelCase Swift:

```swift
enum CodingKeys: String, CodingKey {
    case op, target, found, direction, degrees, revolutions, seconds, text, confidence
    case box2d     = "box_2d"
    case distanceM = "distance_m"
    case deltaM    = "delta_m"
}
```

The `id` field is set by `MissionExecutor` (loop index) after decode; the backend never emits it.

### Backend API error codes

| Status | Meaning |
|---|---|
| `400` | Image content-type is not `image/*` |
| `413` | Image exceeds 10 MB |
| `502` | FreeSolo service unreachable or returned an error |
| `503` | FreeSolo not configured (`FREESOLO_BASE_URL` / key / model env vars missing) |
| `500` | Unhandled backend error (`detail` field contains traceback) |

---

## 5. Drone Default Behavior

When no mission is running and the session is active, the drone runs:
```swift
behaviors.followPerson(maxSeconds: 600, overheadMode: true)
// appState = .executing(verb: "OVERHEAD", target: "operator")
```
- Climbs to 4 m AGL
- Gimbal points straight down
- Vision-tracks the nearest person (the operator)
- Yaw follows AirPods heading
- Auto-renews every 10 minutes

Any voice command interrupts this and the drone returns to overhead hold after the mission completes.

---

## 6. DJI Connection Stability

### Reconnect Strategy (DJIManager)
1. `appRegisteredWithError` → `startConnectionToProduct()`
2. On disconnect → `scheduleReconnect()` with exponential backoff: 2, 4, 8, 16, 30 s (max)
3. Each retry: `DJISDKManager.stopConnectionToProduct()` then `startConnectionToProduct()`
4. `forceReconnect()` — UI-callable; resets attempt counter and retries immediately

### Telemetry Watchdog (DJISDKBridge)
- Resets on every `flightController(_:didUpdate state:)` call
- Fires after 6 s of silence while `isAircraftConnected == true`
- Posts `Notification.Name.djiTelemetryStalled`
- DJIManager subscribes → calls `forceReconnect()`

### Virtual Stick Init
- Deferred 1.5 s after `onProductConnected` to let the DJI SDK fully initialize
- `recheckVirtualStick()` available to re-enable if DJI Fly app steals the session

---

## 7. Training the FreeSolo Model

```bash
# Run from WSL
cd /mnt/d/projects/nimbus/Nimbus/FreeSoloBackend

# (Re)generate dataset
python scripts/generate_dataset.py --count 4000 --eval-count 400

# Push training environment
flash env push --name voice-drone-v2 .

# Format check (free, ~$0.09)
flash train configs/smoke_v2.toml --dry-run
flash train configs/smoke_v2.toml

# Main SFT (~10-15 min, Qwen3.5-4B, 120 steps)
flash train configs/sft_v2.toml

# Deploy and update .env
flash deploy <run-id>
# Set FREESOLO_MODEL=<run-id> in backend/.env and FreeSoloBackend/.env
```
