from __future__ import annotations
import argparse
import json
import random
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from objective import dumps_objective, make_objective  # noqa: E402

TRAIN_PATH = ROOT / "dataset" / "train.jsonl"
EVAL_PATH = ROOT / "dataset" / "eval.jsonl"

TARGETS = [
    "tree", "oak tree", "picnic table", "people at picnic table", "red tent",
    "blue tent", "white car", "black truck", "bike", "dog", "person waving",
    "person in red jacket", "group of people", "bench", "park bench", "flagpole",
    "soccer goal", "basketball hoop", "playground", "kids on playground",
    "frisbee", "orange cone", "cooler", "grill", "food truck", "statue",
    "fountain", "stop sign", "building entrance", "doorway", "yellow backpack",
    "umbrella", "blanket on the grass", "crowd", "stage", "bridge", "archway",
    "tunnel", "gazebo", "fence", "gate", "hill", "rock", "boulder", "bush",
    "flower bed", "pond", "lake edge", "path", "trail", "mailbox", "lamp post",
]

PREFIXES = ["nimbus ", "drone ", "drone, ", "hey ", "okay ", "please ", "uh ", "um ", "hey drone "]
SUFFIXES = ["", " please", " thanks", " now", " real quick", " uh"]
THEN = [" then ", " and then ", " after that ", ", then ", " and ", ", and "]

DURATIONS = [2, 3, 5, 8, 10, 15, 20, 30, 45, 60]
DISTANCES = [1, 2, 3, 5, 8, 10, 15, 20]
YAWS = [90, -90, 180, -180, 360, -360, 45, -45, 270]
PITCHES = [-10, -15, -20, -30, -45, 0, 10]


def row(inp: str, actions: list[dict], confidence: float) -> dict:
    return {
        "input": inp.strip(),
        "output": dumps_objective(make_objective(actions, confidence)),
    }


def noise(text: str, rng: random.Random) -> str:
    out = text
    if rng.random() < 0.3:
        out = rng.choice(PREFIXES) + out
    if rng.random() < 0.25:
        out = out + rng.choice(SUFFIXES)
    swaps = [
        ("picture", "pic"), ("photo", "foto"), ("the ", "da "), ("to ", "too "),
        ("table", "tabel"), ("people", "peple"), ("through", "thru"),
        ("around", "arond"), ("hover", "hoven"), ("return", "re turn"),
        ("spin", "spinn"), ("orbit", "orbitt"),
    ]
    if rng.random() < 0.35:
        a, b = rng.choice(swaps)
        out = out.replace(a, b)
    if rng.random() < 0.12 and len(out) > 10:
        i = rng.randint(0, len(out) - 1)
        if out[i].isalpha():
            out = out[:i] + rng.choice("aeiou") + out[i + 1 :]
    if rng.random() < 0.2:
        out = out.lower()
    return re.sub(r"\s+", " ", out).strip(" ,")


def join_seq(parts: list[str], rng: random.Random) -> str:
    if len(parts) == 1:
        return parts[0]
    out = parts[0]
    for p in parts[1:]:
        out += rng.choice(THEN) + p
    return out


# --- single-action phrase builders return (utterance_fragment, action_dict) ---

def gen_fly_to(rng: random.Random) -> tuple[str, dict]:
    t = rng.choice(TARGETS)
    phrase = rng.choice([
        f"fly to the {t}", f"go to the {t}", f"head to the {t}",
        f"fly over to the {t}", f"find the {t}", f"go find the {t}",
        f"move toward the {t}", f"approach the {t}", f"get to the {t}",
    ])
    return phrase, {"op": "fly_to", "target": t}


def gen_photo(rng: random.Random) -> tuple[str, dict]:
    phrase = rng.choice([
        "take a picture", "take a photo", "take a pic", "snap a photo",
        "photograph it", "get a shot", "capture a photo", "shoot a picture",
    ])
    return phrase, {"op": "photo"}


def gen_photo_of(rng: random.Random) -> tuple[str, list[dict]]:
    """Compound: often fly_to + photo as one spoken phrase."""
    t = rng.choice(TARGETS)
    phrase = rng.choice([
        f"take a picture of the {t}", f"photograph the {t}",
        f"snap a photo of the {t}", f"get a shot of the {t}",
        f"fly to the {t} and take a picture",
        f"go to the {t} and take a photo",
        f"find the {t} and photograph it",
    ])
    return phrase, [{"op": "fly_to", "target": t}, {"op": "photo"}]


def gen_return(rng: random.Random) -> tuple[str, dict]:
    phrase = rng.choice([
        "come back", "come back here", "come back to me", "return",
        "return to me", "return to station", "fly back", "fly back here",
        "come home", "get back over here", "rejoin station",
    ])
    return phrase, {"op": "return"}


def gen_spin(rng: random.Random) -> tuple[str, dict]:
    yaw = rng.choice(YAWS)
    if abs(yaw) == 360:
        phrase = rng.choice(["spin around", "spin", "do a spin", "twirl", "rotate all the way around", "turn around fully"])
    elif abs(yaw) == 180:
        phrase = rng.choice(["turn around", "spin 180", "face the other way", "rotate 180"])
        if yaw < 0:
            phrase = rng.choice([phrase, "turn around the other way"])
    elif yaw > 0:
        phrase = rng.choice([f"spin {int(yaw)} degrees", f"yaw right {int(yaw)}", f"turn right {int(yaw)} degrees", f"rotate {int(yaw)} degrees clockwise"])
    else:
        phrase = rng.choice([f"spin {int(abs(yaw))} degrees left", f"yaw left {int(abs(yaw))}", f"turn left {int(abs(yaw))} degrees"])
    return phrase, {"op": "spin", "yaw_deg": float(yaw)}


def gen_hover(rng: random.Random) -> tuple[str, dict]:
    d = rng.choice(DURATIONS)
    phrase = rng.choice([
        f"hover for {d} seconds", f"hover {d} seconds", f"stay put for {d} seconds",
        f"hold for {d} seconds", f"hang there for {d} seconds",
    ])
    return phrase, {"op": "hover", "duration_s": float(d)}


def gen_hover_station(rng: random.Random) -> tuple[str, dict]:
    phrase = rng.choice([
        "hover", "just hover", "hold station", "hover station", "stay above me",
        "hold position", "stay put", "keep station", "don't move",
    ])
    return phrase, {"op": "hover_station"}


def gen_orbit(rng: random.Random) -> tuple[str, dict]:
    t = rng.choice(TARGETS)
    if rng.random() < 0.5:
        rev = rng.choice([1, 1.5, 2, 3])
        phrase = rng.choice([
            f"orbit the {t}", f"circle the {t}", f"fly around the {t}",
            f"orbit around the {t} {rev} times", f"circle the {t} {rev} times",
        ])
        return phrase, {"op": "orbit", "target": t, "revolutions": float(rev)}
    d = rng.choice(DURATIONS)
    phrase = rng.choice([
        f"orbit the {t} for {d} seconds", f"circle the {t} for {d} seconds",
    ])
    return phrase, {"op": "orbit", "target": t, "duration_s": float(d)}


def gen_follow(rng: random.Random) -> tuple[str, dict]:
    t = rng.choice(TARGETS)
    d = rng.choice(DURATIONS)
    phrase = rng.choice([
        f"follow the {t} for {d} seconds", f"track the {t} for {d} seconds",
        f"follow that {t} for {d} seconds", f"keep following the {t} for {d} seconds",
    ])
    return phrase, {"op": "follow", "target": t, "duration_s": float(d)}


def gen_fly_rel(rng: random.Random) -> tuple[str, dict]:
    direction = rng.choice(["forward", "back", "left", "right", "up", "down"])
    words = {
        "forward": ["forward", "ahead", "straight ahead"],
        "back": ["back", "backward", "backwards"],
        "left": ["left", "to the left"],
        "right": ["right", "to the right"],
        "up": ["up", "higher", "upward"],
        "down": ["down", "lower", "downward"],
    }
    w = rng.choice(words[direction])
    if rng.random() < 0.6:
        dist = rng.choice(DISTANCES)
        phrase = rng.choice([
            f"fly {w} {dist} meters", f"go {w} {dist} meters",
            f"move {w} about {dist} meters", f"nudge {w} {dist} meters",
        ])
        return phrase, {"op": "fly_rel", "direction": direction, "distance_m": float(dist)}
    d = rng.choice([2, 3, 5, 8, 10])
    phrase = rng.choice([
        f"fly {w} for {d} seconds", f"go {w} for {d} seconds",
    ])
    return phrase, {"op": "fly_rel", "direction": direction, "duration_s": float(d)}


def gen_fly_under(rng: random.Random) -> tuple[str, dict]:
    t = rng.choice(TARGETS)
    phrase = rng.choice([
        f"fly under the {t}", f"go under the {t}", f"pass under the {t}",
        f"duck under the {t}", f"slip under the {t}",
    ])
    return phrase, {"op": "fly_under", "target": t}


def gen_fly_through(rng: random.Random) -> tuple[str, dict]:
    t = rng.choice(["archway", "tunnel", "gate", "doorway", "bridge", "gazebo"] + TARGETS[:5])
    phrase = rng.choice([
        f"fly through the {t}", f"go through the {t}", f"pass through the {t}",
        f"shoot through the {t}",
    ])
    return phrase, {"op": "fly_through", "target": t}


def gen_fly_over(rng: random.Random) -> tuple[str, dict]:
    t = rng.choice(TARGETS)
    phrase = rng.choice([
        f"fly over the {t}", f"pass over the {t}", f"go over the {t}",
        f"skim over the {t}",
    ])
    return phrase, {"op": "fly_over", "target": t}


def gen_land(rng: random.Random) -> tuple[str, dict]:
    phrase = rng.choice([
        "land", "land now", "please land", "touch down", "set down",
        "bring it down", "we're done", "end the flight", "land the drone",
    ])
    return phrase, {"op": "land"}


def gen_abort(rng: random.Random) -> tuple[str, dict]:
    phrase = rng.choice([
        "stop", "stop now", "abort", "abort mission", "cancel", "cancel that",
        "never mind", "halt", "drone stop", "kill the mission",
    ])
    return phrase, {"op": "abort"}


def gen_say(rng: random.Random) -> tuple[str, dict]:
    cases = [
        ("what time is it", "I only handle flight commands."),
        ("play some music", "I only handle flight commands."),
        ("who are you", "I'm the drone command router."),
        ("tell me a joke", "I only handle flight commands."),
        ("asdfghjkl", "Sorry, I didn't catch that. Try a flight command."),
        ("um", "Sorry, I didn't catch that. Try a flight command."),
        ("hello", "Ready. Say a flight command."),
        ("thanks", "You're welcome."),
        ("what can you do", "I can fly, photo, orbit, follow, spin, hover, return, and land."),
    ]
    inp, text = rng.choice(cases)
    return inp, {"op": "say", "text": text}


def gen_wait(rng: random.Random) -> tuple[str, dict]:
    d = rng.choice(DURATIONS)
    phrase = rng.choice([f"wait {d} seconds", f"pause for {d} seconds", f"hold on for {d} seconds"])
    return phrase, {"op": "wait", "duration_s": float(d)}


def gen_gimbal(rng: random.Random) -> tuple[str, dict]:
    p = rng.choice(PITCHES)
    if p < 0:
        phrase = rng.choice([f"tilt camera down {int(abs(p))} degrees", f"look down {int(abs(p))}", f"gimbal pitch {p}"])
    elif p > 0:
        phrase = rng.choice([f"tilt camera up {int(p)} degrees", f"look up {int(p)}", f"gimbal pitch {p}"])
    else:
        phrase = rng.choice(["level the camera", "gimbal level", "look straight"])
    return phrase, {"op": "gimbal", "pitch_deg": float(p)}


SINGLE_BUILDERS = [
    (gen_fly_to, 0.10),
    (gen_return, 0.06),
    (gen_spin, 0.07),
    (gen_hover, 0.06),
    (gen_hover_station, 0.04),
    (gen_orbit, 0.07),
    (gen_follow, 0.06),
    (gen_fly_rel, 0.08),
    (gen_fly_under, 0.05),
    (gen_fly_through, 0.05),
    (gen_fly_over, 0.04),
    (gen_land, 0.05),
    (gen_abort, 0.05),
    (gen_say, 0.03),
    (gen_wait, 0.03),
    (gen_gimbal, 0.03),
    (gen_photo, 0.04),
]


def pick_builder(rng: random.Random):
    builders, weights = zip(*SINGLE_BUILDERS)
    return rng.choices(builders, weights=weights, k=1)[0]


def generate_one(rng: random.Random) -> dict:
    conf = round(rng.uniform(0.82, 0.99), 2)
    mode = rng.random()

    # photo-of compounds (~12%)
    if mode < 0.12:
        phrase, actions = gen_photo_of(rng)
        return row(noise(phrase, rng), actions, conf)

    # multi-step sequences (~45%)
    if mode < 0.57:
        n = rng.choices([2, 3, 4, 5], weights=[0.45, 0.35, 0.15, 0.05], k=1)[0]
        parts: list[str] = []
        actions: list[dict] = []
        used_ops: set[str] = set()
        for _ in range(n):
            # Avoid stacking abort/land mid-sequence except at end
            for _try in range(8):
                b = pick_builder(rng)
                phrase, act = b(rng)
                op = act["op"]
                if op in {"abort", "land", "say"} and len(actions) < n - 1:
                    continue
                if op == "abort" and "abort" in used_ops:
                    continue
                break
            parts.append(phrase)
            actions.append(act)
            used_ops.add(act["op"])
        # Classic demo patterns boost
        if rng.random() < 0.15:
            t = rng.choice(TARGETS)
            parts = [
                rng.choice([f"fly to the {t}", f"go to the {t}"]),
                "take a picture",
                rng.choice(["spin around", "turn around"]),
                rng.choice(["come back", "come back to me", "return"]),
            ]
            actions = [
                {"op": "fly_to", "target": t},
                {"op": "photo"},
                {"op": "spin", "yaw_deg": 360.0},
                {"op": "return"},
            ]
            # maybe trim
            if rng.random() < 0.4:
                k = rng.randint(2, 4)
                parts, actions = parts[:k], actions[:k]
        return row(noise(join_seq(parts, rng), rng), actions, conf)

    # single action
    b = pick_builder(rng)
    phrase, act = b(rng)
    return row(noise(phrase, rng), [act], conf)


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=40000)
    ap.add_argument("--eval-count", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()
    rng = random.Random(args.seed)

    seen: set[str] = set()
    rows: list[dict] = []
    target = args.count + args.eval_count
    attempts = 0
    max_attempts = target * 30
    while len(rows) < target and attempts < max_attempts:
        attempts += 1
        r = generate_one(rng)
        key = r["input"].lower()
        if key in seen:
            continue
        seen.add(key)
        rows.append(r)
        if len(rows) % 5000 == 0:
            print(f"generated {len(rows)}/{target}", flush=True)

    rng.shuffle(rows)
    eval_n = min(args.eval_count, max(1, len(rows) // 15))
    eval_rows = rows[:eval_n]
    train_rows = rows[eval_n : eval_n + args.count]
    write_jsonl(TRAIN_PATH, train_rows)
    write_jsonl(EVAL_PATH, eval_rows)
    print(f"Wrote {len(train_rows)} -> {TRAIN_PATH}")
    print(f"Wrote {len(eval_rows)} -> {EVAL_PATH}")
    if len(train_rows) < args.count:
        print(f"[warn] only {len(train_rows)} unique (wanted {args.count})", file=sys.stderr)


if __name__ == "__main__":
    main()
