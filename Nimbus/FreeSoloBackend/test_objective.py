"""Unit tests for the OBJECTIVE grammar (run: python -m pytest test_objective.py)."""

from __future__ import annotations

import json

from objective import (
    OPS,
    dumps_objective,
    make_objective,
    normalize_objective,
    parse_and_normalize,
    parse_step,
    score_objectives,
)


def test_every_op_parses():
    samples = {
        "takeoff": {"op": "takeoff"},
        "land": {"op": "land"},
        "fly_to|red tent": {"op": "fly_to", "target": "red tent"},
        "fly_direction|forward": {"op": "fly_direction", "direction": "forward"},
        "fly_direction|left|2": {"op": "fly_direction", "direction": "left", "distance_m": 2.0},
        "change_altitude": {"op": "change_altitude", "delta_m": 0.5},
        "change_altitude|+2": {"op": "change_altitude", "delta_m": 2.0},
        "change_altitude|-1.5": {"op": "change_altitude", "delta_m": -1.5},
        "rotate|left": {"op": "rotate", "direction": "left", "yaw_deg": -90.0},
        "rotate|right|360": {"op": "rotate", "direction": "right", "yaw_deg": 360.0},
        "orbit|tree": {"op": "orbit", "target": "tree", "revolutions": 1.0},
        "orbit|tree|2": {"op": "orbit", "target": "tree", "revolutions": 2.0},
        "hover": {"op": "hover", "duration_s": 5.0},
        "hover|10": {"op": "hover", "duration_s": 10.0},
        "look_at|fountain": {"op": "look_at", "target": "fountain"},
        "photo": {"op": "photo"},
        "selfie": {"op": "selfie"},
        "panorama": {"op": "panorama"},
        "follow|dog": {"op": "follow", "target": "dog", "duration_s": 30.0},
        "follow|dog|45": {"op": "follow", "target": "dog", "duration_s": 45.0},
        "return": {"op": "return"},
        "abort": {"op": "abort"},
        "say|Ready.": {"op": "say", "text": "Ready."},
    }
    covered_ops = {s.split("|")[0] for s in samples}
    assert covered_ops == set(OPS), f"uncovered: {set(OPS) - covered_ops}"
    for step, expected in samples.items():
        assert parse_step(step) == expected, step


def test_fly_direction_parsing():
    assert parse_step("fly_direction|forward") == {"op": "fly_direction", "direction": "forward"}
    assert parse_step("fly_direction|left|2") == {"op": "fly_direction", "direction": "left", "distance_m": 2.0}
    assert parse_step("fly_direction|backward|3") == {"op": "fly_direction", "direction": "back", "distance_m": 3.0}


def test_legacy_fly_to_direction_compatibility():
    assert parse_step("fly_to|forward") == {"op": "fly_direction", "direction": "forward"}
    assert parse_step("fly_to|left|2") == {"op": "fly_direction", "direction": "left", "distance_m": 2.0}
    assert parse_step("fly_to|backward|3") == {"op": "fly_direction", "direction": "back", "distance_m": 3.0}


def test_lenient_aliases():
    assert parse_step("fly_higher|2", lenient=True) == {"op": "change_altitude", "delta_m": 2.0}
    assert parse_step("descend|3", lenient=True) == {"op": "change_altitude", "delta_m": -3.0}
    assert parse_step("climb", lenient=True) == {"op": "change_altitude", "delta_m": 0.5}
    assert parse_step("fly_forward|2", lenient=True) == {"op": "fly_direction", "direction": "forward", "distance_m": 2.0}
    assert parse_step("circle|tree|2", lenient=True) == {"op": "orbit", "target": "tree", "revolutions": 2.0}
    assert parse_step("spin|360", lenient=True) == {"op": "rotate", "direction": "right", "yaw_deg": 360.0}
    # Critical v3 fix: 'fly_up' must map to change_altitude, NOT fly_to
    assert parse_step("fly_up", lenient=True) == {"op": "change_altitude", "delta_m": 0.5}
    assert parse_step("fly_up|2", lenient=True) == {"op": "change_altitude", "delta_m": 2.0}
    assert parse_step("fly_down|1.5", lenient=True) == {"op": "change_altitude", "delta_m": -1.5}
    # strict mode rejects near-miss aliases
    assert parse_step("fly_higher|2") is None
    assert parse_step("circle|tree") is None
    assert parse_step("fly_up") is None


def test_invalid_steps_rejected():
    for bad in ["", "warp_speed", "fly_to", "fly_to|", "rotate", "rotate|up",
                "orbit", "follow", "say",
                "land|now|please|extra".replace("land", "unknown")]:
        assert parse_step(bad) is None, bad
    # unknown extra args on no-arg ops are tolerated (op wins)
    assert parse_step("land|now") == {"op": "land"}


def test_normalize_and_roundtrip():
    obj = make_objective(["fly_to|tree", "photo", "rotate|right|360", "return"], 0.9)
    text = dumps_objective(obj)
    norm = parse_and_normalize(text)
    assert norm is not None
    assert norm["steps"] == ["fly_to|tree", "photo", "rotate|right|360", "return"]
    assert [a["op"] for a in norm["actions"]] == ["fly_to", "photo", "rotate", "return"]
    assert norm["confidence"] == 0.9


def test_parse_from_noisy_output():
    raw = 'Sure! ```json\n{"steps":["fly_to|dog","photo"],"confidence":0.8}\n``` hope that helps'
    norm = parse_and_normalize(raw)
    assert norm is not None
    assert norm["actions"][0] == {"op": "fly_to", "target": "dog"}


def test_bad_objective_none():
    assert parse_and_normalize("not json at all") is None
    assert normalize_objective({"steps": []}) is None
    assert normalize_objective({"steps": ["warp_speed|9"]}) is None
    assert normalize_objective({}) is None


def test_say_with_pipes():
    act = parse_step("say|One: do this | two: do that")
    assert act is not None and "two: do that" in act["text"]


def test_scoring():
    gold = parse_and_normalize(json.dumps({"steps": ["fly_to|tree", "photo"], "confidence": 0.9}))
    same = parse_and_normalize(json.dumps({"steps": ["fly_to|tree", "photo"], "confidence": 0.5}))
    close = parse_and_normalize(json.dumps({"steps": ["fly_to|bush", "photo"], "confidence": 0.9}))
    wrong = parse_and_normalize(json.dumps({"steps": ["land"], "confidence": 0.9}))
    assert score_objectives(same, gold) == 1.0
    assert 0.4 < score_objectives(close, gold) < 1.0
    assert score_objectives(wrong, gold) < 0.3
    assert score_objectives(None, gold) == 0.0
