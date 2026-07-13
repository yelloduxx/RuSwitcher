#!/usr/bin/env python3
"""Run a labelled mixed-layout TSV corpus through RuSwitcherSimulator."""

from __future__ import annotations

import argparse
import collections
import csv
import json
import re
import subprocess
import sys
from pathlib import Path


SEPARATOR = re.compile(r"(?:\s+|\\t)")
SOURCE_LANGUAGE = {
    "en_wrong": "ru",
    "ru_wrong": "en",
    "en_correct": "en",
    "ru_correct": "ru",
}

EN_TO_RU = dict(zip(
    "qwertyuiop[]asdfghjkl;'zxcvbnm,./\\`",
    "йцукенгшщзхъфывапролджэячсмитьбю.ёё",
))
EN_TO_RU.update(dict(zip(
    'QWERTYUIOP{}ASDFGHJKL:"ZXCVBNM<>?|~',
    'ЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,ЁЁ',
)))
EN_TO_RU["&"] = "?"
RU_TO_EN = {value: key for key, value in EN_TO_RU.items()}
RU_TO_EN["ё"] = "`"
RU_TO_EN["Ё"] = "~"


def physical_wrong_input(expected: str, pattern: str) -> str:
    """Produce what the intended token emits in the opposite active layout.

    The source TSV keeps many punctuation marks literal while corrupting only
    letters. That cannot be produced by physical keyboard input for layout-
    dependent keys such as comma, period and question mark.
    """
    mapping = EN_TO_RU if pattern == "en_wrong" else RU_TO_EN
    return "".join(mapping.get(char, char) for char in expected)


def split_text(value: str) -> tuple[list[str], list[str]]:
    return [part for part in SEPARATOR.split(value) if part], SEPARATOR.findall(value)


def inferred_language(token: str) -> str:
    latin = sum("a" <= char.lower() <= "z" for char in token)
    cyrillic = sum("а" <= char.lower() <= "я" or char.lower() == "ё" for char in token)
    return "ru" if cyrillic > latin else "en"


def convert_corpus(source: Path, destination: Path) -> tuple[int, list[str]]:
    destination.parent.mkdir(parents=True, exist_ok=True)
    phrase_count = 0
    token_patterns: list[str] = []
    with source.open(encoding="utf-8-sig", newline="") as input_file, destination.open(
        "w", encoding="utf-8", newline="\n"
    ) as output_file:
        reader = csv.DictReader(input_file, delimiter="\t")
        required = {"wrong_input", "expected_output", "token_pattern"}
        if set(reader.fieldnames or ()) != required:
            raise ValueError(f"expected TSV columns {sorted(required)}, got {reader.fieldnames}")

        for line_number, row in enumerate(reader, start=2):
            typed_tokens, typed_separators = split_text(row["wrong_input"])
            expected_tokens, expected_separators = split_text(row["expected_output"])
            patterns = row["token_pattern"].split(",")
            if not (len(typed_tokens) == len(expected_tokens) == len(patterns)):
                raise ValueError(f"token count mismatch at TSV line {line_number}")
            if typed_separators != expected_separators:
                raise ValueError(f"separator mismatch at TSV line {line_number}")

            steps = []
            for index, (typed, expected, pattern) in enumerate(
                zip(typed_tokens, expected_tokens, patterns)
            ):
                if pattern == "technical_unchanged":
                    source_language = inferred_language(typed)
                    verdict = "keep"
                else:
                    try:
                        source_language = SOURCE_LANGUAGE[pattern]
                    except KeyError as error:
                        raise ValueError(
                            f"unknown token pattern {pattern!r} at TSV line {line_number}"
                        ) from error
                    verdict = "switch" if pattern.endswith("_wrong") else "keep"
                    if verdict == "switch":
                        typed = physical_wrong_input(expected, pattern)
                steps.append(
                    {
                        "typed": typed,
                        "manualLanguage": source_language,
                        "separator": typed_separators[index]
                        if index < len(typed_separators)
                        else "",
                        "expected": verdict,
                        "expectedResolved": expected,
                    }
                )

            fixture = {
                "id": f"mixed-layout-{phrase_count + 1:05d}",
                "initialLanguage": steps[0]["manualLanguage"] if steps else "en",
                "steps": steps,
                "expectedText": row["expected_output"],
            }
            output_file.write(json.dumps(fixture, ensure_ascii=False, separators=(",", ":")))
            output_file.write("\n")
            phrase_count += 1
            token_patterns.extend(patterns)
    return phrase_count, token_patterns


def build_token_audit(traces: Path, patterns: list[str]) -> dict[str, object]:
    steps: list[dict[str, object]] = []
    with traces.open(encoding="utf-8") as trace_file:
        for line in trace_file:
            steps.extend(json.loads(line)["steps"])
    if len(steps) != len(patterns):
        raise ValueError(f"trace contains {len(steps)} steps for {len(patterns)} labels")

    totals: collections.Counter[str] = collections.Counter()
    passed: collections.Counter[str] = collections.Counter()
    failure_kinds: collections.Counter[str] = collections.Counter()
    for pattern, step in zip(patterns, steps):
        totals[pattern] += 1
        if step["passed"]:
            passed[pattern] += 1
            continue
        if step["expectedVerdict"] == "keep":
            failure_kinds["falsePositive"] += 1
        elif step["actualResolved"] == step["typed"]:
            failure_kinds["safeMiss"] += 1
        else:
            failure_kinds["wrongReplacement"] += 1

    token_total = len(steps)
    token_passed = sum(1 for step in steps if step["passed"])
    return {
        "tokenTotal": token_total,
        "tokenPassed": token_passed,
        "tokenFailed": token_total - token_passed,
        "tokenAccuracy": token_passed / token_total if token_total else 1.0,
        "byPattern": {
            pattern: {
                "total": totals[pattern],
                "passed": passed[pattern],
                "failed": totals[pattern] - passed[pattern],
                "accuracy": passed[pattern] / totals[pattern],
            }
            for pattern in sorted(totals)
        },
        "failureKinds": dict(sorted(failure_kinds.items())),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("tsv", type=Path)
    parser.add_argument("--engine", choices=("v3", "v4-shadow", "v4-active"), default="v4-shadow")
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--audit", type=Path)
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    build = root / ".build"
    generated = build / "mixed-layout-5000-phrases.jsonl"
    traces = build / "mixed-layout-5000-traces.jsonl"
    report = args.report or build / "mixed-layout-5000-report.json"
    audit_path = args.audit or build / "mixed-layout-5000-audit.json"
    empty_words = build / "mixed-layout-empty-words.jsonl"
    empty_words.parent.mkdir(parents=True, exist_ok=True)
    empty_words.write_text("", encoding="utf-8")

    phrase_count, token_patterns = convert_corpus(args.tsv, generated)
    print(f"Prepared {phrase_count} phrases / {len(token_patterns)} tokens", flush=True)
    command = [
        "swift", "run", "-c", "release", "RuSwitcherSimulator",
        "--engine", args.engine,
        "--jobs", str(max(1, args.jobs)),
        "--input", str(empty_words),
        "--phrase-input", str(generated),
        "--output", str(report),
        "--phrase-results", str(traces),
    ]
    completed = subprocess.run(command, cwd=root, check=False, stdout=subprocess.DEVNULL)
    if not report.exists():
        return completed.returncode or 1
    summary = json.loads(report.read_text(encoding="utf-8"))
    audit = build_token_audit(traces, token_patterns)
    audit.update({"phraseTotal": summary["phraseTotal"], "phrasePassed": summary["phrasePassed"]})
    audit_path.write_text(json.dumps(audit, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(
        json.dumps(
            {
                "total": summary["total"],
                "passed": summary["passed"],
                "failed": summary["failed"],
                "phraseTotal": summary["phraseTotal"],
                "phrasePassed": summary["phrasePassed"],
                "v4LatencyP95": summary.get("v4LatencyP95"),
                "v4LatencyP99": summary.get("v4LatencyP99"),
                "tokenTotal": audit["tokenTotal"],
                "tokenPassed": audit["tokenPassed"],
                "tokenAccuracy": audit["tokenAccuracy"],
                "failureKinds": audit["failureKinds"],
                "report": str(report),
                "traces": str(traces),
                "audit": str(audit_path),
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    if summary["phraseFailures"]:
        print("First failing phrase IDs:", file=sys.stderr)
        for failure in summary["phraseFailures"][:20]:
            print(f"  {failure['id']}", file=sys.stderr)
    return 0 if summary["failed"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
