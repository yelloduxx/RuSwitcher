#!/usr/bin/env python3
"""Run the labelled TSV through the full headless input/transaction stream."""

from __future__ import annotations

import argparse
import collections
import json
import subprocess
import sys
from pathlib import Path

from run_mixed_layout_tsv_suite import convert_corpus


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("tsv", type=Path)
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--max-safe-misses", type=int, default=443)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--results", type=Path)
    parser.add_argument("--audit", type=Path)
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    build = root / ".build"
    generated = build / "mixed-layout-5000-event-stream-input.jsonl"
    report = args.report or build / "mixed-layout-5000-event-stream-report.json"
    results = args.results or build / "mixed-layout-5000-event-stream-results.jsonl"
    audit_path = args.audit or build / "mixed-layout-5000-event-stream-audit.json"

    phrase_count, token_patterns = convert_corpus(args.tsv, generated)
    command = [
        "swift", "run", "-c", "release", "RuSwitcherTypingSimulator",
        "--jobs", str(max(1, args.jobs)),
        "--phrase-input", str(generated),
        "--output", str(report),
        "--results", str(results),
    ]
    completed = subprocess.run(command, cwd=root, stdout=subprocess.DEVNULL, check=False)
    if completed.returncode not in (0, 1) or not report.exists() or not results.exists():
        return completed.returncode or 1

    traces: list[dict[str, object]] = []
    with results.open(encoding="utf-8") as handle:
        for line in handle:
            traces.extend(json.loads(line)["traces"])
    if len(traces) != len(token_patterns):
        raise ValueError(f"trace contains {len(traces)} tokens for {len(token_patterns)} labels")

    expected_steps: list[dict[str, object]] = []
    with generated.open(encoding="utf-8") as handle:
        for line in handle:
            expected_steps.extend(json.loads(line)["steps"])
    if len(expected_steps) != len(traces):
        raise ValueError("generated fixture and event trace token counts differ")

    totals: collections.Counter[str] = collections.Counter()
    passed: collections.Counter[str] = collections.Counter()
    failure_kinds: collections.Counter[str] = collections.Counter()
    for pattern, step, trace in zip(token_patterns, expected_steps, traces):
        totals[pattern] += 1
        expected_switch = step["expected"] == "switch"
        actual_switch = trace["verdict"] == "switchToConverted"
        if expected_switch and not actual_switch:
            failure_kinds["safeMiss"] += 1
        elif expected_switch and trace["resolvedText"] != step["expectedResolved"]:
            failure_kinds["wrongReplacement"] += 1
        elif not expected_switch and actual_switch:
            failure_kinds["falsePositive"] += 1
        else:
            passed[pattern] += 1

    summary = json.loads(report.read_text(encoding="utf-8"))
    safe_misses = failure_kinds["safeMiss"]
    quality_passed = (
        failure_kinds["falsePositive"] == 0
        and failure_kinds["wrongReplacement"] == 0
        and safe_misses <= args.max_safe_misses
        and summary["duplicateTransactionCount"] == 0
    )
    audit = {
        "qualityPassed": quality_passed,
        "phraseTotal": phrase_count,
        "phrasePassed": summary["fixturePassed"],
        "tokenTotal": len(traces),
        "tokenPassed": len(traces) - sum(failure_kinds.values()),
        "failureKinds": dict(sorted(failure_kinds.items())),
        "maxSafeMisses": args.max_safe_misses,
        "workers": summary["workers"],
        "elapsedMilliseconds": summary["elapsedMilliseconds"],
        "actualTransactions": summary["actualTransactions"],
        "duplicateTransactionCount": summary["duplicateTransactionCount"],
        "byPattern": {
            pattern: {
                "total": totals[pattern],
                "passed": passed[pattern],
                "failed": totals[pattern] - passed[pattern],
            }
            for pattern in sorted(totals)
        },
    }
    audit_path.write_text(json.dumps(audit, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(audit, ensure_ascii=False, indent=2))
    return 0 if quality_passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
