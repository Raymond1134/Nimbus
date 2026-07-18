"""Unit tests for OBJECTIVE → mid-level InstructionStep expansion."""

from planner import (
    InstructionStep,
    expand_objective_skeleton,
    plan_mission,
    resolve_step,
)


def test_expand_compound_order():
    objective = {
        "actions": [
            {"op": "fly_to", "target": "person in red jacket"},
            {"op": "photo"},
            {"op": "spin", "yaw_deg": 360.0},
            {"op": "land"},
        ],
        "confidence": 0.95,
    }
    steps = expand_objective_skeleton(objective)
    assert [s.op for s in steps] == ["fly_to", "photo", "rotate", "land"]
    assert steps[0].target == "person in red jacket"
    assert steps[0].needs_grounding is True
    assert steps[2].yaw_deg == 360.0


def test_expand_altitude_and_orbit():
    objective = {
        "actions": [
            {"op": "fly_rel", "direction": "up", "distance_m": 3.0},
            {"op": "fly_over", "target": "picnic table"},
            {"op": "orbit", "target": "tree", "revolutions": 1.0},
            {"op": "follow", "target": "dog", "duration_s": 8.0},
        ],
        "confidence": 0.85,
    }
    steps = expand_objective_skeleton(objective)
    assert steps[0].op == "fly_higher" and steps[0].altitude_delta_m == 3.0
    assert steps[1].op == "fly_above" and steps[1].needs_grounding
    assert steps[2].op == "orbit" and steps[2].radius_m == 5.0
    assert steps[3].op == "follow" and steps[3].duration_s == 8.0


def test_plan_mission_empty_objective():
    jpeg = (
        b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
        b"\xff\xdb\x00C\x00\x08\x06\x06\x07\x06\x05\x08\x07\x07\x07\t\t"
        b"\x08\n\x0c\x14\r\x0c\x0b\x0b\x0c\x19\x12\x13\x0f\x14\x1d\x1a"
        b"\x1f\x1e\x1d\x1a\x1c\x1c $.' \",#\x1c\x1c(7),01444\x1f'9=82<.342\x1e"
        b"\xff\xc0\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00"
        b"\xff\xc4\x00\x1f\x00\x00\x01\x05\x01\x01\x01\x01\x01\x01\x00\x00"
        b"\x00\x00\x00\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07\x08\t\n\x0b"
        b"\xff\xc4\x00\xb5\x10\x00\x02\x01\x03\x03\x02\x04\x03\x05\x05\x04"
        b"\x04\x00\x00\x01}\x01\x02\x03\x00\x04\x11\x05\x12!1A\x06\x13Qa"
        b"\x07\"q\x142\x81\x91\xa1\x08#B\xb1\xc1\x15R\xd1\xf0$3br\x82\t\n"
        b"\x16\x17\x18\x19\x1a%&'()*456789:CDEFGHIJSTUVWXYZ"
        b"cdefghijstuvwxyz\x83\x84\x85\x86\x87\x88\x89\x8a\x92\x93\x94\x95"
        b"\x96\x97\x98\x99\x9a\xa2\xa3\xa4\xa5\xa6\xa7\xa8\xa9\xaa\xb2\xb3"
        b"\xb4\xb5\xb6\xb7\xb8\xb9\xba\xc2\xc3\xc4\xc5\xc6\xc7\xc8\xc9\xca"
        b"\xd2\xd3\xd4\xd5\xd6\xd7\xd8\xd9\xda\xe1\xe2\xe3\xe4\xe5\xe6\xe7"
        b"\xe8\xe9\xea\xf1\xf2\xf3\xf4\xf5\xf6\xf7\xf8\xf9\xfa"
        b"\xff\xda\x00\x08\x01\x01\x00\x00?\x00\xfb\xd4P\x00\x00\x00\x1f\xff\xd9"
    )
    plan = plan_mission({"actions": [], "confidence": 0.0}, jpeg)
    assert plan.blocked
    assert plan.steps[0].op == "say"


def test_resolve_step_non_visual_noop():
    step = InstructionStep(id=2, op="rotate", yaw_deg=-45.0)
    out = resolve_step(step, b"not-an-image")
    assert out.op == "rotate"
    assert out.needs_grounding is False


if __name__ == "__main__":
    test_expand_compound_order()
    test_expand_altitude_and_orbit()
    test_plan_mission_empty_objective()
    test_resolve_step_non_visual_noop()
    print("All planner unit tests passed.")
