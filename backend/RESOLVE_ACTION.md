# resolve_action — Gemini Disambiguation Layer

## Why this layer exists

**The FreeSolo / Gemini division of labor**

Nimbus uses two AI models in its voice-command pipeline:

1. **FreeSolo** — a fine-tuned, OpenAI-compatible speech-to-intent model.  
   It converts a voice transcript into a structured intent (e.g. `"seek_and_photo"`)
   and extracts a raw `target` string from the spoken words.

2. **Gemini (gemini-2.5-flash)** — Google's multimodal model.  
   It handles all vision tasks: looking at the drone's camera frame and locating
   objects within it.

**The untrained ambiguity problem**

FreeSolo was fine-tuned to identify *intent* (what the user wants the drone to do)
and extract a *target* (the object of that action). However, it was **not** trained
to distinguish between three fundamentally different kinds of target:

| Type | Examples | Drone action |
|------|----------|-------------|
| **Object** | "pillar", "red trash can", "person in jacket" | Visual search → rotate to center → fly forward |
| **Direction** | "left", "north", "forward", "ahead" | Lateral translation |
| **Altitude** | "up", "higher", "descend", "go up 3 meters" | Vertical movement |

All three arrive as the same plain string in FreeSolo's `"target"` field with no
flag indicating which type it is. We cannot retrain FreeSolo before the hackathon
deadline, so `resolve_action` uses Gemini as a post-processing disambiguation step
that sits between FreeSolo's raw output and the drone's flight logic.

---

## Input schema

`POST /resolve_action` — multipart form data

| Field | Type | Description |
|-------|------|-------------|
| `image` | `UploadFile` (image/*) | Current drone camera frame. Max 10 MB. Required. |
| `target` | `str` | Raw target string extracted by FreeSolo. Required. |
| `intent` | `str` | Raw intent string from FreeSolo (e.g. `"seek_and_photo"`). Required. |

The image is downscaled to a maximum 768 px longest edge before being sent to
Gemini (same preprocessing as `/ground_target`).

---

## Output schema — `ActionResolution`

```json
{
  "action_type": "seek_object | fly_direction | change_altitude",
  "box_2d":          [ymin, xmin, ymax, xmax],
  "direction":       "left | right | forward | backward | north | south | east | west",
  "altitude_delta_m": 1.5,
  "reasoning":       "One-sentence explanation of the classification."
}
```

| Field | Type | Populated when | Meaning |
|-------|------|----------------|---------|
| `action_type` | `str` (Literal) | Always | Classification result. One of `seek_object`, `fly_direction`, `change_altitude`. |
| `box_2d` | `list[int]` | `action_type == "seek_object"` | Bounding box `[ymin, xmin, ymax, xmax]` normalized to 0–1000. Empty list `[]` if the object is not visible in the frame. |
| `direction` | `str` | `action_type == "fly_direction"` | Canonical direction word. One of: `left`, `right`, `forward`, `backward`, `north`, `south`, `east`, `west`. Empty string otherwise. |
| `altitude_delta_m` | `float` | `action_type == "change_altitude"` | Signed metres to move vertically. Positive = up, negative = down. `0.0` otherwise. If the spoken phrase gives no specific distance, Gemini defaults to ±1.0 m. |
| `reasoning` | `str` | Always | Short explanation of the classification decision, intended for debugging and demo narration. |

---

## Example inputs and outputs

### Case 1 — seek_object

**Request**
```
image:  <drone frame containing a red trash can>
target: "red trash can"
intent: "seek_and_photo"
```

**Response**
```json
{
  "action_type": "seek_object",
  "box_2d": [320, 410, 780, 620],
  "direction": "",
  "altitude_delta_m": 0.0,
  "reasoning": "The target 'red trash can' is a physical object; it is visible in the lower-center of the frame."
}
```

---

### Case 2 — fly_direction

**Request**
```
image:  <any drone camera frame>
target: "left"
intent: "fly_direction"
```

**Response**
```json
{
  "action_type": "fly_direction",
  "box_2d": [],
  "direction": "left",
  "altitude_delta_m": 0.0,
  "reasoning": "The target 'left' is a lateral direction word, not a physical object or altitude instruction."
}
```

---

### Case 3 — change_altitude

**Request**
```
image:  <any drone camera frame>
target: "up higher"
intent: "change_altitude"
```

**Response**
```json
{
  "action_type": "change_altitude",
  "box_2d": [],
  "direction": "",
  "altitude_delta_m": 1.0,
  "reasoning": "The target 'up higher' clearly indicates upward vertical movement; no specific distance was given so defaulting to +1.0 m."
}
```

---

## Important note on `box_2d` and flight execution

When `action_type == "seek_object"` and `box_2d` is non-empty, the bounding box
is intended to feed into a **hardcoded iOS-side function** in the Nimbus app that:

1. Rotates the drone (yaw) to center the bounding box horizontally in the frame.
2. Flies forward a fixed **1 metre**.

**Gemini's job ends at classification and localization.**
All flight math — yaw angle calculation, forward distance, Virtual Stick commands —
is implemented entirely on the iOS side and is outside the scope of this layer.

---

## Note on `/voice_command` integration

The `/voice_command` route currently calls `annotate_steps()` (which calls
`ground_target()` internally) rather than `ground_target()` directly, so
`resolve_action` is **not yet chained** into the voice pipeline.

`/resolve_action` is currently a standalone route. A future step should wire it
in: after FreeSolo returns an OBJECTIVE, for any `fly_to` / `seek` / directional
action whose `target` is ambiguous, call `resolve_action()` with the image and the
raw target before dispatching to `annotate_steps`.
