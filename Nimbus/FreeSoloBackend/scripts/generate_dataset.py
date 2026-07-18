#!/usr/bin/env python3
"""Generate (transcript -> OBJECTIVE JSON) SFT data for the intent model (v2).

Covers every op in the 14-op v2 grammar (objective.OPS) with varied phrasing,
ASR-style noise, compound multi-step commands, classic demo sequences, and
non-flight negatives that map to `say`.

  python scripts/generate_dataset.py --count 4000 --eval-count 400
"""

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
    "tree", "oak tree", "pine tree", "picnic table", "people at the picnic table",
    "red tent", "blue tent", "white car", "black truck", "silver suv", "bike",
    "motorcycle", "dog", "golden retriever", "person waving", "person in the red jacket",
    "guy in the blue shirt", "group of people", "bench", "park bench", "flagpole",
    "soccer goal", "basketball hoop", "playground", "kids on the playground",
    "orange cone", "cooler", "grill", "food truck", "statue", "fountain",
    "stop sign", "building entrance", "doorway", "yellow backpack", "umbrella",
    "blanket on the grass", "crowd", "stage", "bridge", "gazebo", "fence",
    "gate", "hill", "big rock", "boulder", "bush", "flower bed", "pond",
    "trail", "mailbox", "lamp post", "trash can", "red trash can", "swing set",
    "volleyball net", "parking lot", "white van", "canopy", "fire pit",
]

FOLLOW_TARGETS = [
    "dog", "golden retriever", "person in the red jacket", "guy in the blue shirt",
    "person waving", "bike", "kid on the scooter", "runner", "jogger", "me",
    "that person", "the skateboarder", "white car", "group walking",
]

PREFIXES = ["nimbus ", "drone ", "drone, ", "hey ", "okay ", "please ", "uh ", "um ", "hey drone ", "alright "]
SUFFIXES = ["", " please", " thanks", " now", " real quick", " for me", " uh"]
THEN = [" then ", " and then ", " after that ", ", then ", " and ", ", and ", " next "]

DURATIONS = [2, 3, 5, 8, 10, 15, 20, 30, 45, 60]
DEGREES = [30, 45, 90, 120, 180, 270, 360]
REVOLUTIONS = [1, 2, 3]
DIST_M = [1, 2, 3, 5, 10]
# change_altitude magnitudes (meters)
ALT_VALUES = [0.5, 1, 1.5, 2, 3, 5]
# Common feet values converted to meters (rounded to 1 decimal)
DIST_FT_TO_M = {1: 0.3, 2: 0.6, 3: 0.9, 5: 1.5, 10: 3.0}


def _num(v) -> str:
    """Format a number without a trailing .0 (1.0 -> '1', 1.5 -> '1.5')."""
    f = float(v)
    return str(int(f)) if f == int(f) else str(f)


def row(inp: str, steps: list[str], confidence: float) -> dict:
    return {"input": inp.strip(), "output": dumps_objective(make_objective(steps, confidence))}


def noise(text: str, rng: random.Random) -> str:
    """Simulate wake words, fillers, and ASR misspellings."""
    out = text
    if rng.random() < 0.3:
        out = rng.choice(PREFIXES) + out
    if rng.random() < 0.25:
        out = out + rng.choice(SUFFIXES)
    swaps = [
        ("picture", "pic"), ("photo", "foto"), ("the ", "da "), ("to ", "too "),
        ("table", "tabel"), ("people", "peple"), ("higher", "hier"),
        ("around", "arond"), ("hover", "hoover"), ("panorama", "pana rama"),
        ("selfie", "selfy"), ("orbit", "orbitt"), ("rotate", "ro tate"),
        ("follow", "fallow"), ("take off", "takeoff"), ("degrees", "degree"),
    ]
    if rng.random() < 0.3:
        a, b = rng.choice(swaps)
        out = out.replace(a, b)
    if rng.random() < 0.1 and len(out) > 10:
        i = rng.randint(0, len(out) - 1)
        if out[i].isalpha():
            out = out[:i] + rng.choice("aeiou") + out[i + 1 :]
    if rng.random() < 0.2:
        out = out.lower()
    return re.sub(r"\s+", " ", out).strip(" ,")


def join_seq(parts: list[str], rng: random.Random) -> str:
    out = parts[0]
    for p in parts[1:]:
        out += rng.choice(THEN) + p
    return out


# --- builders return (utterance_fragment, step_string) ------------------------

def gen_takeoff(rng: random.Random) -> tuple[str, str]:
    phrase = rng.choice([
        "take off", "takeoff", "lift off", "launch", "get in the air",
        "spin up and take off", "up you go", "start flying", "take flight",
    ])
    return phrase, "takeoff"


def gen_land(rng: random.Random) -> tuple[str, str]:
    phrase = rng.choice([
        "land", "land now", "please land", "touch down", "set down",
        "bring it down and land", "we're done, land", "end the flight", "land the drone",
    ])
    return phrase, "land"


def gen_fly_to(rng: random.Random) -> tuple[str, str]:
    t = rng.choice(TARGETS)
    phrase = rng.choice([
        f"fly to the {t}", f"go to the {t}", f"head to the {t}",
        f"fly over to the {t}", f"find the {t}", f"go find the {t}",
        f"move toward the {t}", f"approach the {t}", f"get to the {t}",
        f"fly towards that {t}", f"go over to that {t}", f"head over to the {t}",
        f"fly behind the {t}", f"go behind that {t}", f"get behind the {t}",
        f"fly past the {t}", f"fly under the {t}", f"go through the {t}",
        f"fly next to the {t}", f"get close to the {t}", f"fly above the {t}",
    ])
    return phrase, f"fly_to|{t}"


def gen_fly_relative(rng: random.Random) -> tuple[str, str]:
    """Relative directional move without a visual target."""
    direction = rng.choice(["forward", "backward", "left", "right"])
    step_dir = "back" if direction == "backward" else direction

    if rng.random() < 0.55:
        # With distance
        if rng.random() < 0.3:
            # Feet (convert to meters in the step)
            ft = rng.choice(list(DIST_FT_TO_M.keys()))
            m = DIST_FT_TO_M[ft]
            phrase = rng.choice([
                f"fly {direction} {ft} {'foot' if ft == 1 else 'feet'}",
                f"move {direction} {ft} {'foot' if ft == 1 else 'feet'}",
                f"go {direction} {ft} {'foot' if ft == 1 else 'feet'}",
            ])
            return phrase, f"fly_to|{step_dir}|{_num(m)}"
        m = rng.choice(DIST_M)
        phrase = rng.choice([
            f"fly {direction} {m} meters",
            f"move {direction} {m} meters",
            f"go {direction} {m} meters",
            f"move {direction} {m} m",
            f"go {direction} {m}m",
        ])
        return phrase, f"fly_to|{step_dir}|{_num(m)}"
    # No distance (app defaults to 0.5 m)
    phrase = rng.choice([
        f"fly {direction}",
        f"move {direction}",
        f"go {direction}",
        f"drift {step_dir}",
        f"nudge {step_dir}",
        f"scoot {step_dir}",
    ])
    return phrase, f"fly_to|{step_dir}"


def gen_change_altitude(rng: random.Random) -> tuple[str, str]:
    """Climb or descend. + = up, - = down. Bare (no value) defaults to +0.5 m."""
    up = rng.random() < 0.5
    with_value = rng.random() < 0.5
    if up:
        if with_value:
            if rng.random() < 0.3:
                ft = rng.choice(list(DIST_FT_TO_M.keys()))
                m = DIST_FT_TO_M[ft]
                phrase = rng.choice([
                    f"go up {ft} {'foot' if ft == 1 else 'feet'}",
                    f"fly up {ft} {'foot' if ft == 1 else 'feet'}",
                    f"climb {ft} {'foot' if ft == 1 else 'feet'}",
                    f"rise {ft} {'foot' if ft == 1 else 'feet'}",
                ])
                return phrase, f"change_altitude|+{_num(m)}"
            m = rng.choice(ALT_VALUES)
            phrase = rng.choice([
                f"go up {_num(m)} meters", f"fly up {_num(m)} meters",
                f"climb {_num(m)} meters", f"rise {_num(m)} meters",
                f"gain {_num(m)} meters of altitude", f"ascend {_num(m)} meters",
            ])
            return phrase, f"change_altitude|+{_num(m)}"
        phrase = rng.choice([
            "go up", "go higher", "fly higher", "climb", "ascend",
            "get some altitude", "up a bit", "gain some height",
            "a little higher", "up you go a bit",
        ])
        return phrase, "change_altitude"
    # descend
    if with_value:
        if rng.random() < 0.3:
            ft = rng.choice(list(DIST_FT_TO_M.keys()))
            m = DIST_FT_TO_M[ft]
            phrase = rng.choice([
                f"go down {ft} {'foot' if ft == 1 else 'feet'}",
                f"fly down {ft} {'foot' if ft == 1 else 'feet'}",
                f"descend {ft} {'foot' if ft == 1 else 'feet'}",
                f"drop {ft} {'foot' if ft == 1 else 'feet'}",
            ])
            return phrase, f"change_altitude|-{_num(m)}"
        m = rng.choice(ALT_VALUES)
        phrase = rng.choice([
            f"go down {_num(m)} meters", f"fly down {_num(m)} meters",
            f"descend {_num(m)} meters", f"drop {_num(m)} meters",
            f"come down {_num(m)} meters", f"lower by {_num(m)} meters",
        ])
        return phrase, f"change_altitude|-{_num(m)}"
    phrase = rng.choice([
        "go down", "go lower", "fly lower", "descend", "come down a bit",
        "drop down a little", "a little lower", "get lower",
    ])
    return phrase, "change_altitude|-0.5"


def gen_rotate(rng: random.Random) -> tuple[str, str]:
    direction = rng.choice(["left", "right"])
    r = rng.random()
    if r < 0.35:
        phrase = rng.choice([
            f"rotate {direction}", f"turn {direction}", f"yaw {direction}",
            f"spin {direction} a bit", f"turn to the {direction}",
        ])
        return phrase, f"rotate|{direction}"
    if r < 0.75:
        deg = rng.choice(DEGREES)
        phrase = rng.choice([
            f"rotate {direction} {deg} degrees", f"turn {direction} {deg} degrees",
            f"yaw {direction} {deg}", f"spin {deg} degrees {direction}",
            f"rotate {deg} degrees to the {direction}",
        ])
        return phrase, f"rotate|{direction}|{deg}"
    # full / half spins
    if rng.random() < 0.5:
        phrase = rng.choice([
            "spin around", "do a spin", "do a full spin", "spin all the way around",
            "rotate 360", "do a 360",
        ])
        return phrase, "rotate|right|360"
    phrase = rng.choice(["turn around", "face the other way", "do a 180", "rotate 180"])
    return phrase, "rotate|right|180"


def gen_orbit(rng: random.Random) -> tuple[str, str]:
    t = rng.choice(TARGETS)
    if rng.random() < 0.5:
        phrase = rng.choice([
            f"orbit the {t}", f"circle the {t}", f"fly around the {t}",
            f"fly in circles around the {t}", f"do a lap around the {t}",
            f"circle around that {t}",
        ])
        return phrase, f"orbit|{t}"
    rev = rng.choice(REVOLUTIONS)
    times_word = {1: "once", 2: "twice", 3: "three times"}[rev]
    phrase = rng.choice([
        f"orbit the {t} {times_word}", f"circle the {t} {times_word}",
        f"fly around the {t} {rev} times" if rev > 1 else f"fly around the {t} once",
        f"do {rev} laps around the {t}" if rev > 1 else f"do a lap around the {t}",
    ])
    return phrase, f"orbit|{t}|{rev}"


def gen_hover(rng: random.Random) -> tuple[str, str]:
    if rng.random() < 0.5:
        d = rng.choice(DURATIONS)
        phrase = rng.choice([
            f"hover for {d} seconds", f"hover {d} seconds", f"stay put for {d} seconds",
            f"hold for {d} seconds", f"hang there for {d} seconds", f"wait {d} seconds",
        ])
        return phrase, f"hover|{d}"
    phrase = rng.choice([
        "hover", "just hover", "hold position", "stay there", "stay put",
        "hold station", "don't move", "stay right there", "hold it",
    ])
    return phrase, "hover"


def gen_look_at(rng: random.Random) -> tuple[str, str]:
    t = rng.choice(TARGETS)
    phrase = rng.choice([
        f"look at the {t}", f"point the camera at the {t}", f"aim at the {t}",
        f"look over at the {t}", f"focus on the {t}", f"point at that {t}",
        f"keep the camera on the {t}", f"watch the {t}",
    ])
    return phrase, f"look_at|{t}"


def gen_photo(rng: random.Random) -> tuple[str, str]:
    phrase = rng.choice([
        "take a picture", "take a photo", "take a pic", "snap a photo",
        "snap a pic", "get a shot", "capture a photo", "shoot a picture",
        "take the shot", "grab a photo",
    ])
    return phrase, "photo"


def gen_selfie(rng: random.Random) -> tuple[str, str]:
    phrase = rng.choice([
        "take a selfie", "selfie", "take a selfie of me", "get a selfie",
        "take a picture of me", "get a shot of me", "take a dronie",
        "snap a selfie", "photo of me please",
    ])
    return phrase, "selfie"


def gen_panorama(rng: random.Random) -> tuple[str, str]:
    phrase = rng.choice([
        "take a panorama", "do a 360 panorama", "take a 360 photo",
        "panorama shot", "do a full panorama", "capture a panorama",
        "take a pano", "shoot a 360", "get a panorama of this place",
    ])
    return phrase, "panorama"


def gen_follow(rng: random.Random) -> tuple[str, str]:
    t = rng.choice(FOLLOW_TARGETS)
    if rng.random() < 0.5:
        d = rng.choice(DURATIONS)
        phrase = rng.choice([
            f"follow the {t} for {d} seconds", f"track the {t} for {d} seconds",
            f"follow that {t} for {d} seconds", f"stay on the {t} for {d} seconds",
        ])
        return phrase, f"follow|{t}|{d}"
    phrase = rng.choice([
        f"follow the {t}", f"follow that {t}", f"track the {t}",
        f"keep up with the {t}", f"tail the {t}", f"stay with the {t}",
    ])
    return phrase, f"follow|{t}"


def gen_return(rng: random.Random) -> tuple[str, str]:
    phrase = rng.choice([
        "come back", "come back here", "come back to me", "return",
        "return to me", "fly back", "fly back here", "come home",
        "get back over here", "fly home", "return home", "come to me",
    ])
    return phrase, "return"


def gen_abort(rng: random.Random) -> tuple[str, str]:
    phrase = rng.choice([
        "stop", "stop now", "abort", "abort mission", "cancel", "cancel that",
        "never mind", "halt", "drone stop", "stop stop stop", "wait stop",
        "forget it",
    ])
    return phrase, "abort"


def gen_say(rng: random.Random) -> tuple[str, str]:
    cases = [
        ("what time is it", "I only handle flight commands."),
        ("play some music", "I only handle flight commands."),
        ("who are you", "I'm Nimbus, your drone copilot."),
        ("tell me a joke", "I only handle flight commands."),
        ("what's the weather like", "I only handle flight commands."),
        ("asdfghjkl", "Sorry, I didn't catch that. Try a flight command."),
        ("um", "Sorry, I didn't catch that. Try a flight command."),
        ("uh hmm", "Sorry, I didn't catch that. Try a flight command."),
        ("hello", "Ready. Say a flight command."),
        ("hey there", "Ready. Say a flight command."),
        ("thanks", "You're welcome."),
        ("good job", "Thanks. What's next?"),
        ("what can you do", "I can take off, fly to things, orbit, follow, take photos, and land."),
        ("how much battery do you have", "Check the app for battery status."),
        ("order me a pizza", "I only handle flight commands."),
    ]
    inp, text = rng.choice(cases)
    return inp, f"say|{text}"


SINGLE_BUILDERS = [
    (gen_takeoff, 0.04),
    (gen_land, 0.04),
    (gen_fly_to, 0.10),
    (gen_fly_relative, 0.08),
    (gen_change_altitude, 0.09),
    (gen_rotate, 0.08),
    (gen_orbit, 0.07),
    (gen_hover, 0.05),
    (gen_look_at, 0.06),
    (gen_photo, 0.05),
    (gen_selfie, 0.04),
    (gen_panorama, 0.04),
    (gen_follow, 0.07),
    (gen_return, 0.05),
    (gen_abort, 0.04),
]

TERMINAL_OPS = {"land", "abort", "return"}


def pick_builder(rng: random.Random):
    builders, weights = zip(*SINGLE_BUILDERS)
    return rng.choices(builders, weights=weights, k=1)[0]


def gen_photo_of(rng: random.Random) -> tuple[str, list[str]]:
    """Compound spoken as one phrase: go to X and photograph it."""
    t = rng.choice(TARGETS)
    phrase = rng.choice([
        f"take a picture of the {t}", f"photograph the {t}",
        f"snap a photo of the {t}", f"get a shot of the {t}",
        f"fly to the {t} and take a picture", f"go to the {t} and take a photo",
        f"find the {t} and photograph it", f"get me a picture of that {t}",
    ])
    return phrase, [f"fly_to|{t}", "photo"]


def gen_demo_sequence(rng: random.Random) -> tuple[list[str], list[str]]:
    """Classic demo patterns worth over-representing."""
    t = rng.choice(TARGETS)
    patterns = [
        (
            [rng.choice([f"fly to the {t}", f"go to the {t}"]),
             "take a picture",
             rng.choice(["spin around", "do a 360"]),
             rng.choice(["come back", "return"])],
            [f"fly_to|{t}", "photo", "rotate|right|360", "return"],
        ),
        (
            ["take off", rng.choice([f"fly to the {t}", f"head to the {t}"]), "take a photo"],
            ["takeoff", f"fly_to|{t}", "photo"],
        ),
        (
            [rng.choice([f"orbit the {t}", f"circle the {t}"]), "then take a panorama", "and come back"],
            [f"orbit|{t}", "panorama", "return"],
        ),
        (
            ["take off", rng.choice(["go up 3 meters", "climb 3 meters"]), "take a panorama"],
            ["takeoff", "change_altitude|+3", "panorama"],
        ),
        (
            [f"fly to the {t}", "take a picture", "come back and land"],
            [f"fly_to|{t}", "photo", "return", "land"],
        ),
        (
            ["take a selfie", "then do a panorama"],
            ["selfie", "panorama"],
        ),
    ]
    parts, steps = rng.choice(patterns)
    if rng.random() < 0.35:
        k = rng.randint(2, len(steps))
        parts, steps = parts[:k], steps[:k]
    return parts, steps


def generate_one(rng: random.Random) -> dict:
    conf = round(rng.uniform(0.82, 0.99), 2)
    mode = rng.random()

    # photo-of compounds (~10%)
    if mode < 0.10:
        phrase, steps = gen_photo_of(rng)
        return row(noise(phrase, rng), steps, conf)

    # classic demo sequences (~8%)
    if mode < 0.18:
        parts, steps = gen_demo_sequence(rng)
        return row(noise(join_seq(parts, rng), rng), steps, conf)

    # random multi-step sequences (~34%)
    if mode < 0.52:
        n = rng.choices([2, 3, 4], weights=[0.5, 0.35, 0.15], k=1)[0]
        parts: list[str] = []
        steps: list[str] = []
        for i in range(n):
            for _try in range(10):
                phrase, step = pick_builder(rng)(rng)
                op = step.split("|")[0]
                # keep terminal ops at the end; no duplicate consecutive ops
                if op in TERMINAL_OPS and i < n - 1:
                    continue
                if steps and steps[-1].split("|")[0] == op:
                    continue
                break
            parts.append(phrase)
            steps.append(step)
        return row(noise(join_seq(parts, rng), rng), steps, conf)

    # non-flight / unintelligible -> say (~5%)
    if mode < 0.57:
        inp, step = gen_say(rng)
        return row(inp, [step], round(rng.uniform(0.5, 0.8), 2))

    # single action (~43%)
    phrase, step = pick_builder(rng)(rng)
    return row(noise(phrase, rng), [step], conf)


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=4000)
    ap.add_argument("--eval-count", type=int, default=400)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()
    rng = random.Random(args.seed)

    seen: set[str] = set()
    rows: list[dict] = []
    target = args.count + args.eval_count
    attempts = 0
    max_attempts = target * 40
    while len(rows) < target and attempts < max_attempts:
        attempts += 1
        r = generate_one(rng)
        key = r["input"].lower()
        if key in seen:
            continue
        seen.add(key)
        rows.append(r)
        if len(rows) % 2000 == 0:
            print(f"generated {len(rows)}/{target}", flush=True)

    rng.shuffle(rows)
    eval_rows = rows[: args.eval_count]
    train_rows = rows[args.eval_count : args.eval_count + args.count]
    write_jsonl(TRAIN_PATH, train_rows)
    write_jsonl(EVAL_PATH, eval_rows)
    print(f"Wrote {len(train_rows)} -> {TRAIN_PATH}")
    print(f"Wrote {len(eval_rows)} -> {EVAL_PATH}")
    if len(train_rows) < args.count:
        print(f"[warn] only {len(train_rows)} unique (wanted {args.count})", file=sys.stderr)


if __name__ == "__main__":
    main()
