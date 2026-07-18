# Voice-Controlled Drone Companion — Project Spec

## 1. What this project is

An iOS app that pairs a DJI Mavic Mini with a user wearing AirPods. The drone
hovers above and slightly behind the user and yaw-follows their head direction
(via AirPods motion data). When the user speaks a command referencing something
they're looking at ("fly in circles around that tree," "fly toward that trash
can"), the app:

1. transcribes the command,
2. grounds the referenced object in the drone's current camera frame,
3. parses the command into a structured action,
4. flies the drone using closed-loop Virtual Stick control (no DJI missions —
   the Mavic Mini's Mobile SDK v4 integration does not expose Waypoint/Hot
   Point/ActiveTrack, only Virtual Stick),
5. plays spatial audio cues through the AirPods reflecting the drone's
   position/state relative to the user.

There is **no second wearable camera**. The drone's own gimbal camera, aimed
by the user's head via AirPods yaw tracking, is the sole vision source. This
was a deliberate simplification — see §7 for rationale — and should not be
silently reintroduced.

## 2. Hardware / SDK constraints (authoritative — do not deviate without reason)

- **Aircraft**: DJI Mavic Mini. No forward/side obstacle sensors — only
  downward vision for position hold. Treat as flying blind on obstacles;
  safety must be procedural (see §8), not sensor-based.
- **DJI Mobile SDK**: v4 only (Mavic Mini is not supported on v5). Swift, iOS.
- **Flight control model**: Virtual Stick only. All flight behaviors
  (orbit, approach, rotate, ascend/descend, hover-hold) are custom closed-loop
  controllers built on top of `sendVirtualStickFlightControlData`, reading
  `FlightController` telemetry at ~10Hz. No DJI mission objects.
- **Audio**: AirPods via `CMHeadphoneMotionManager` for head attitude
  (relative yaw/pitch/roll — no true-north reference, must be calibrated
  against phone compass at session start) and `AVAudioEngine` /
  `AVAudioEnvironmentNode` (or PHASE) for spatial playback.
- **Phone**: connects to the Mavic Mini RC via cable, runs the whole app.
  Assume mid-to-high-end iPhone (A15+) for on-device CoreML inference budget.

## 3. Components and their single responsibility

| # | Component | Responsibility | Runs where |
|---|---|---|---|
| 1 | **Voice Capture & STT** | Mic capture, push-to-talk trigger, streaming transcript via ElevenLabs | On-device (audio) + ElevenLabs API |
| 2 | **Intent Parser** | Transcript text → structured command JSON (verb, target description, parameters) | Fine-tuned small LLM (FreeSolo SFT run), served via OpenAI-compatible endpoint |
| 3 | **Object Detector** | Continuous, real-time bounding boxes + labels on the current drone camera frame | On-device CoreML (YOLOv8n/YOLOv11n), Neural Engine |
| 4 | **Object Tracker** | Maintains identity of a specific box across frames after grounding, without re-running detection/grounding every frame | On-device, Vision framework (`VNTrackObjectRequest`) |
| 5 | **Grounding Model** | Given transcript + frame + candidate boxes, selects which box (or region) the user means; may return "no match" | Cloud VLM call (vision-capable LLM), triggered once per command |
| 6 | **Head Tracking / Hover-Follow** | Calibrates AirPods yaw against compass north; yaw-follows drone to match user's head direction when idle; freezes during an active command | On-device, `CMHeadphoneMotionManager` |
| 7 | **Coordinate / Distance Estimator** | Rough far-range distance via bbox-size heuristic; drives closed-loop visual servoing instead of committing to one estimate | On-device, part of the flight control loop |
| 8 | **Flight Behavior Library** | `approach`, `orbit`, `rotateToFace`, `ascend`/`descend`, `holdPosition` — each a Virtual Stick control loop | On-device, Swift, talks to DJI SDK |
| 9 | **Safety Supervisor** | Geofence/altitude limits, speed clamp, dead-man's-switch heartbeat, standoff-distance enforcement, kill-switch | On-device, wraps every command to Behavior Library |
| 10 | **Spatial Audio Feedback** | Converts live telemetry (bearing, distance, battery, warnings) into panned/pitched audio cues | On-device, `AVAudioEngine` + head-tracking data |
| 11 | **Orchestrator / State Machine** | Owns the command lifecycle end to end, listed in §5 | On-device, ties everything above together |

## 4. Data contracts

These are the interfaces between components. A coding agent should implement
these as concrete types and treat them as the integration seams.

**Transcript event** (Voice Capture → Intent Parser)
```json
{ "text": "fly towards that trash can", "timestamp": 1737219600.123, "is_final": true }
```

**Structured command** (Intent Parser → Orchestrator)
```json
{
  "verb": "approach | orbit | ascend | descend | rotate | stop | land",
  "target_description": "trash can",
  "parameters": { "radius_m": null, "direction": null, "standoff_m": 3.0 }
}
```

**Detected object** (Object Detector → Orchestrator / Grounding Model)
```json
{
  "id": "obj_0007",
  "label": "trash can",
  "confidence": 0.81,
  "bbox": { "x": 0.42, "y": 0.55, "w": 0.08, "h": 0.12 }
}
```
(bbox in normalized 0-1 frame coordinates)

**Grounding result** (Grounding Model → Orchestrator)
```json
{
  "matched_object_id": "obj_0007",
  "matched": true,
  "fallback_region": null,
  "confidence": "high | low"
}
```

**Flight target** (Orchestrator → Flight Behavior Library)
```json
{
  "verb": "approach",
  "bearing_deg": 34.5,
  "estimated_distance_m": 12.0,
  "standoff_m": 3.0,
  "tracked_object_id": "obj_0007"
}
```

**Telemetry snapshot** (Flight Controller → Safety Supervisor, Spatial Audio, Orchestrator)
```json
{
  "gps": { "lat": 0.0, "lon": 0.0, "alt_m": 0.0 },
  "heading_deg": 0.0,
  "velocity_mps": { "x": 0.0, "y": 0.0, "z": 0.0 },
  "battery_pct": 0,
  "distance_to_home_m": 0.0
}
```

## 5. Command lifecycle (the sequence to implement)

1. **Idle state**: drone holds hover position at fixed offset above/behind
   user; Object Detector runs continuously; Head Tracking yaw-follows the
   drone to match the user's calibrated head heading; Spatial Audio plays
   ambient telemetry cues.
2. **Push-to-talk pressed**: Voice Capture starts streaming to ElevenLabs.
   Head Tracking freezes yaw-follow (drone stops rotating, holding current
   view) — this is the frame the grounding step will use.
3. **Transcript finalized**: send in parallel:
   - transcript → Intent Parser → structured command
   - current frame + current Object Detector boxes + transcript →
     Grounding Model → matched object id (or fallback)
4. **Merge**: Orchestrator combines structured command + matched object into
   a Flight Target. If grounding returns `matched: false`, abort and play an
   audio "not found" cue; do not guess.
5. **Handoff to tracker**: Object Tracker locks onto the matched box so
   Detector/Grounding aren't needed again mid-flight; periodic re-detection
   (~1/sec) re-anchors the tracker.
6. **Execute**: Safety Supervisor wraps the call, then the relevant Flight
   Behavior primitive runs its closed-loop control, using tracker output +
   bbox-size distance heuristic for far range, switching to fine positioning
   as the target fills more of the frame.
7. **Completion / interrupt**: behavior completes (reaches standoff, orbit
   loop count done, etc.), user says "stop," or dead-man's-switch/geofence
   trips. Any of these returns to Idle state and re-enables yaw-follow.

## 6. Fine-tuning track (FreeSolo)

FreeSolo (LoRA SFT/GRPO/OPD on sub-10B **text** models, agent-driven CLI,
fixed-price quote) fits the **Intent Parser only** — it does not support
vision models, so it is not a fit for the Grounding Model.

- Generate a synthetic dataset of (transcript → structured command JSON)
  pairs covering the verb set in §4, including ambiguous/edge phrasing.
- Use `algorithm = "sft"` since this is a direct example-based task, not one
  needing a hand-designed reward.
- Train, `flash deploy`, and call the resulting endpoint (OpenAI-compatible)
  from the Orchestrator in place of a general-purpose LLM call — this is
  what makes the fine-tune load-bearing rather than incidental, which
  matters both for latency/offline-reliability and for the prize track.

## 7. Design decisions already made (do not re-litigate without new information)

- **No second wearable camera.** The drone's own camera, aimed via AirPods
  head-tracking yaw-follow, is the single vision source. Simpler rigging, no
  cross-device sync, and avoids fusing two disagreeing viewpoints.
- **No dedicated depth-estimation model.** Bbox-size heuristic + closed-loop
  visual servoing replaces it; a separate depth model adds noise without
  reliable metric accuracy at these ranges (LiDAR too short-range, monocular
  depth only gives relative ordering).
- **Grounding uses frame + candidate boxes together**, not detector-label
  vector search alone and not a raw freeform-photo query alone — this gives
  both recall (works even if the label vocabulary doesn't include the exact
  word) and constraint (reduces hallucinated pixel coordinates).
- **Missions are not used.** Everything is Virtual Stick. Do not add
  Waypoint/Hot Point code paths for this airframe.

## 8. Safety requirements (non-negotiable for demo day)

- Hard geofence radius + max altitude set via SDK flight-limitation APIs,
  independent of app logic.
- Velocity output clamp (~1-2 m/s) on every Virtual Stick command during
  demos.
- Dead-man's-switch: no fresh command within ~300ms → zero velocity, hold.
- Minimum standoff distance enforced in the Flight Target, never let
  "approach" resolve to "reach" the object.
- Safety pilot holds the physical RC throughout; virtual-stick-disable is
  the instant override.
- All behavior primitives tested in DJI's SDK simulator before any outdoor
  flight.

## 9. Suggested iOS module layout

```
/VoiceDrone
  /Orchestrator        -- state machine, owns command lifecycle (§5)
  /Voice                -- ElevenLabs streaming client, push-to-talk
  /IntentParser          -- FreeSolo-served endpoint client
  /Vision
    /Detector            -- CoreML YOLO wrapper
    /Tracker              -- VNTrackObjectRequest wrapper
    /Grounding            -- VLM client, frame+boxes payload builder
  /HeadTracking          -- CMHeadphoneMotionManager, calibration, yaw-follow
  /FlightControl
    /DJISDKBridge          -- FlightController state polling, VirtualStick send
    /Behaviors              -- approach.swift, orbit.swift, rotateToFace.swift, etc.
    /SafetySupervisor        -- geofence, clamp, dead-man's switch, standoff
  /SpatialAudio           -- AVAudioEngine graph, telemetry-to-cue mapping
  /Models                  -- shared data contracts from §4
```

## 10. Open parameters to fill in before/during build

- Exact hover offset (height/behind-distance) above the user.
- Standoff distance default per verb.
- Orbit radius default and direction convention (CW/CCW on "circle").
- Push-to-talk vs. continuous listening (recommend push-to-talk for demo
  reliability — avoids false triggers from ambient noise/crowd at judging).
- Re-detection interval (suggested ~1s, tune against tracker drift observed
  in testing).
- Grounding confidence threshold below which the app should ask for
  clarification instead of acting.
