#!/usr/bin/env python3
"""Build a deterministic random mixed-layout HID fixture from the user corpus."""

from __future__ import annotations

import argparse
import csv
import json
import random
import re
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


def split_text(value: str) -> tuple[list[str], list[str]]:
    return [part for part in SEPARATOR.split(value) if part], SEPARATOR.findall(value)


def language_of(token: str) -> str:
    cyrillic = sum("а" <= char.lower() <= "я" or char.lower() == "ё" for char in token)
    latin = sum("a" <= char.lower() <= "z" for char in token)
    return "ru" if cyrillic > latin else "en"


def wrong_layout_text(expected: str, pattern: str) -> str:
    mapping = EN_TO_RU if pattern == "en_wrong" else RU_TO_EN
    return "".join(mapping.get(char, char) for char in expected)


def has_punctuation(text: str) -> bool:
    return any(char in ".,?!:;()[]{}\"'/-" for char in text)


def load_candidates(path: Path) -> list[dict[str, object]]:
    candidates: list[dict[str, object]] = []
    with path.open(encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for index, row in enumerate(reader, start=1):
            expected_tokens, separators = split_text(row["expected_output"])
            patterns = row["token_pattern"].split(",")
            if len(expected_tokens) != len(patterns):
                continue
            kinds = set(patterns)
            has_wrong = any(kind.endswith("_wrong") for kind in kinds)
            has_correct = any(kind.endswith("_correct") or kind == "technical_unchanged" for kind in kinds)
            languages = {language_of(token) for token in expected_tokens}
            if not (has_wrong and has_correct and len(languages) == 2 and has_punctuation(row["expected_output"])):
                continue
            candidates.append({
                "id": f"mixed-layout-{index:05d}",
                "expected": row["expected_output"],
                "tokens": expected_tokens,
                "separators": separators,
                "patterns": patterns,
            })
    return candidates


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("corpus", type=Path)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("--count", type=int, default=30)
    parser.add_argument("--seed", type=int, default=7701)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()

    candidates = load_candidates(args.corpus)
    if len(candidates) < args.count:
        raise SystemExit(f"only {len(candidates)} eligible phrases for requested {args.count}")
    selected = random.Random(args.seed).sample(candidates, args.count)

    phases: list[dict[str, str]] = []
    expected_lines: list[str] = []
    source_ids: list[str] = []
    for phrase in selected:
        source_ids.append(str(phrase["id"]))
        expected_lines.append(str(phrase["expected"]))
        tokens = phrase["tokens"]
        separators = phrase["separators"]
        patterns = phrase["patterns"]
        for token_index, (token, pattern) in enumerate(zip(tokens, patterns)):
            if pattern == "technical_unchanged":
                source_language = language_of(token)
                typed = token
            else:
                source_language = SOURCE_LANGUAGE[pattern]
                typed = wrong_layout_text(token, pattern) if pattern.endswith("_wrong") else token
            separator = separators[token_index] if token_index < len(separators) else ""
            if token_index == len(tokens) - 1:
                separator += "\n"
            phases.append({"sourceLanguage": source_language, "text": typed + separator})

    fixture = {
        "name": f"random-mixed-phrases-{args.count}-seed-{args.seed}",
        "sourceIDs": source_ids,
        "inputModel": "physical opposite-layout keys for wrong tokens; original keys for correct tokens",
        "phases": phases,
        "expectedText": "\n".join(expected_lines) + "\n",
    }
    args.fixture.parent.mkdir(parents=True, exist_ok=True)
    args.fixture.write_text(json.dumps(fixture, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if args.manifest:
        args.manifest.write_text(
            "\n".join(f"{item['id']}\t{item['expected']}" for item in selected) + "\n",
            encoding="utf-8",
        )
    print(f"generated {args.fixture}: {len(selected)} phrases, {len(phases)} token phases, seed={args.seed}")


if __name__ == "__main__":
    main()
