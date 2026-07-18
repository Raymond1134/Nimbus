from __future__ import annotations
from pathlib import Path
from freesolo.datasets import TaskExample
from freesolo.datasets.records import load_task_examples
from freesolo.environments import EnvironmentSingleTurn, RewardResult
from objective import SYSTEM_PROMPT, parse_and_normalize, score_objectives

ROOT = Path(__file__).parent


class VoiceDroneObjectiveEnv(EnvironmentSingleTurn):
    def __init__(self, *, split: str = "train", dataset_path: str | None = None) -> None:
        if dataset_path:
            path = Path(dataset_path)
            if not path.is_absolute():
                path = ROOT / path
        else:
            path = ROOT / "dataset" / f"{split}.jsonl"
            if not path.exists():
                path = ROOT / "dataset" / "train.jsonl"
        self.dataset = load_task_examples(path)

    def build_prompt_messages(self, example: TaskExample, prompt_text: str):
        system = (prompt_text or "").strip() or SYSTEM_PROMPT
        return [
            {"role": "system", "content": system},
            {"role": "user", "content": example.input},
        ]

    def score_response(self, example: TaskExample, response_text: str) -> RewardResult:
        predicted = parse_and_normalize(str(response_text))
        expected = parse_and_normalize(str(example.output or ""))
        score = score_objectives(predicted, expected)
        return RewardResult(score=score, threshold=1.0)


def load_environment(
    split: str = "train", dataset_path: str | None = None, **kwargs
) -> VoiceDroneObjectiveEnv:
    return VoiceDroneObjectiveEnv(split=split, dataset_path=dataset_path)
