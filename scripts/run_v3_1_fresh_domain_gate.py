#!/usr/bin/env python3
"""Run V3 and V3.1 against the opened GlobalVoices diagnostic corpus."""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import tempfile
import urllib.request
import zipfile
from itertools import zip_longest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = ROOT / "scripts" / "v3_1_fresh_domain_gate.json"
BUILD = ROOT / ".build"
ARCHIVE = BUILD / "corpora" / "GlobalVoices-v2018q4-en-ru.txt.zip"
FIXTURES = BUILD / "v3.1-fresh-domain-fixtures.jsonl"
LEADING = "([{<\"'«„“‘"
TRAILING = ".,!?;:)]}>\"'»”’…_-—–"

EN_TO_RU = dict(zip(
    "qwertyuiop[]asdfghjkl;'zxcvbnm,./\\`",
    "йцукенгшщзхъфывапролджэячсмитьбю.ёё",
))
EN_TO_RU.update(dict(zip(
    'QWERTYUIOP{}ASDFGHJKL:"ZXCVBNM<>?|~',
    'ЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,ЁЁ',
)))
EN_TO_RU.update({"&": "?", "@": '"', "#": "№", "$": ";", "^": ":"})
RU_TO_EN = {value: key for key, value in EN_TO_RU.items()}
RU_TO_EN.update({"ё": "`", "Ё": "~", ".": "/", ",": "?", "?": "&"})


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def ensure_archive(manifest: dict[str, object]) -> None:
    ARCHIVE.parent.mkdir(parents=True, exist_ok=True)
    if ARCHIVE.exists() and sha256(ARCHIVE) == manifest["sha256"]:
        return
    with tempfile.NamedTemporaryFile(dir=ARCHIVE.parent, delete=False) as temporary:
        temporary_path = Path(temporary.name)
    try:
        urllib.request.urlretrieve(str(manifest["url"]), temporary_path)
        actual = sha256(temporary_path)
        if actual != manifest["sha256"]:
            raise ValueError(f"fresh corpus checksum mismatch: {actual}")
        temporary_path.replace(ARCHIVE)
    finally:
        temporary_path.unlink(missing_ok=True)


def stable_hash(*values: str) -> int:
    digest = hashlib.sha256("\0".join(values).encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big")


def dominant_language(value: str) -> str | None:
    latin = sum("a" <= character.lower() <= "z" for character in value)
    cyrillic = sum("а" <= character.lower() <= "я" or character.lower() == "ё" for character in value)
    if latin > cyrillic:
        return "en"
    if cyrillic > latin:
        return "ru"
    return None


def lexical_core(token: str) -> str:
    start = 0
    end = len(token)
    while start < end and token[start] in LEADING:
        start += 1
    while end > start and token[end - 1] in TRAILING:
        end -= 1
    return token[start:end]


def eligible_for_wrong_layout(token: str, language: str) -> bool:
    core = lexical_core(token)
    if not core or dominant_language(core) != language:
        return False
    letters = "".join(character for character in core if character.isalpha())
    if not letters or (len(letters) == 1 and letters.isupper()):
        return False
    if len(letters) > 1 and letters.isupper():
        return False
    if any(character.isdigit() for character in core):
        return False
    if any(marker in token for marker in ("://", "@", "_", "\\")):
        return False
    if "/" in core or len(core) > 40:
        return False
    mapping = RU_TO_EN if language == "ru" else EN_TO_RU
    return all(not character.isalpha() or character in mapping for character in token)


def physical_wrong(token: str, language: str) -> str:
    mapping = RU_TO_EN if language == "ru" else EN_TO_RU
    return "".join(mapping.get(character, character) for character in token)


def sentence_parts(sentence: str, maximum: int, seed: int) -> list[tuple[str, str]]:
    matches = list(re.finditer(r"(\S+)(\s*)", sentence.strip()))
    if len(matches) <= maximum:
        selected = matches
    else:
        start = seed % (len(matches) - maximum + 1)
        selected = matches[start:start + maximum]
    return [(match.group(1), match.group(2)) for match in selected]


def fixture(
    identifier: str,
    sentence: str,
    language: str,
    manifest: dict[str, object],
) -> dict[str, object] | None:
    seed = stable_hash(str(manifest["salt"]), identifier, language)
    parts = sentence_parts(sentence, int(manifest["maximumTokensPerPhrase"]), seed)
    if len(parts) < int(manifest["minimumTokensPerPhrase"]):
        return None
    eligible = [
        index for index, (token, _) in enumerate(parts)
        if eligible_for_wrong_layout(token, language)
    ]
    if len(eligible) < 2:
        return None
    wrong = {
        index for index in eligible
        if stable_hash(str(manifest["salt"]), identifier, language, str(index)) % 2 == 0
    }
    if not wrong:
        wrong.add(eligible[0])
    if len(wrong) == len(eligible):
        wrong.remove(eligible[-1])

    steps: list[dict[str, object]] = []
    expected_text = ""
    for index, (expected, separator) in enumerate(parts):
        token_language = dominant_language(lexical_core(expected)) or language
        should_switch = index in wrong and token_language == language
        typed = physical_wrong(expected, language) if should_switch else expected
        if should_switch and typed == expected:
            should_switch = False
        source_language = ("ru" if language == "en" else "en") if should_switch else token_language
        steps.append({
            "typed": typed,
            "manualLanguage": source_language,
            "separator": separator,
            "expected": "switch" if should_switch else "keep",
            "expectedResolved": expected,
        })
        expected_text += expected + separator
    if not any(step["expected"] == "switch" for step in steps):
        return None
    return {
        "id": f"globalvoices-{identifier}-{language}",
        "initialLanguage": steps[0]["manualLanguage"],
        "steps": steps,
        "expectedText": expected_text,
    }


def generate(manifest: dict[str, object]) -> tuple[int, int]:
    maximum = int(manifest["maximumPhrases"])
    candidates: list[tuple[int, dict[str, object]]] = []
    with zipfile.ZipFile(ARCHIVE) as archive:
        with archive.open(str(manifest["englishEntry"])) as english, archive.open(
            str(manifest["russianEntry"])
        ) as russian:
            missing = object()
            pairs = zip_longest(english, russian, fillvalue=missing)
            for line_number, (en_raw, ru_raw) in enumerate(pairs, start=1):
                if en_raw is missing or ru_raw is missing:
                    exhausted = (
                        str(manifest["englishEntry"])
                        if en_raw is missing
                        else str(manifest["russianEntry"])
                    )
                    remaining = (
                        str(manifest["russianEntry"])
                        if en_raw is missing
                        else str(manifest["englishEntry"])
                    )
                    raise ValueError(
                        "fresh corpus line count mismatch at line "
                        f"{line_number}: {exhausted} ended before {remaining}"
                    )
                en = en_raw.decode("utf-8").strip()
                ru = ru_raw.decode("utf-8").strip()
                if not en or not ru or len(en) > 800 or len(ru) > 800:
                    continue
                pair_id = f"{line_number:08d}"
                for language, sentence in (("en", en), ("ru", ru)):
                    value = fixture(pair_id, sentence, language, manifest)
                    if value is not None:
                        order = stable_hash(str(manifest["salt"]), pair_id, language, "order")
                        candidates.append((order, value))
    candidates.sort(key=lambda item: item[0])
    selected = [value for _, value in candidates[:maximum]]
    if len(selected) != maximum:
        raise ValueError(f"only {len(selected)} usable fresh-domain phrases")
    FIXTURES.parent.mkdir(parents=True, exist_ok=True)
    with FIXTURES.open("w", encoding="utf-8", newline="\n") as output:
        for value in selected:
            output.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
    return len(selected), sum(len(value["steps"]) for value in selected)


def fixture_shape(path: Path) -> list[tuple[str, int]]:
    shape: list[tuple[str, int]] = []
    with path.open(encoding="utf-8") as input_file:
        for line_number, line in enumerate(input_file, start=1):
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"invalid fixture JSONL at line {line_number}") from error
            if not isinstance(value, dict):
                raise ValueError(f"fixture JSONL line {line_number} is not an object")
            identifier = value.get("id")
            steps = value.get("steps")
            if not isinstance(identifier, str) or not isinstance(steps, list):
                raise ValueError(f"invalid fixture shape at line {line_number}")
            shape.append((identifier, len(steps)))
    if len({identifier for identifier, _ in shape}) != len(shape):
        raise ValueError("fixture IDs must be unique")
    return shape


def load_engine_outputs(
    engine: str,
    report: Path,
    traces: Path,
    expected_shape: list[tuple[str, int]],
) -> tuple[dict[str, object], dict[str, int]]:
    try:
        summary = json.loads(report.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"{engine} simulator report is missing or invalid") from error
    if not isinstance(summary, dict):
        raise ValueError(f"{engine} simulator report is not an object")

    counts = {"correct": 0, "falsePositives": 0, "wrongReplacements": 0, "safeMisses": 0}
    actual_shape: list[tuple[str, int]] = []
    phrase_passed = 0
    try:
        input_file = traces.open(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise ValueError(f"{engine} simulator traces are missing or invalid") from error
    with input_file:
        for line_number, line in enumerate(input_file, start=1):
            if not line.strip():
                continue
            try:
                phrase = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(
                    f"invalid {engine} simulator trace JSON at line {line_number}"
                ) from error
            if not isinstance(phrase, dict):
                raise ValueError(f"{engine} simulator trace line {line_number} is not an object")
            identifier = phrase.get("id")
            steps = phrase.get("steps")
            passed = phrase.get("passed")
            if (
                not isinstance(identifier, str)
                or not isinstance(steps, list)
                or not isinstance(passed, bool)
            ):
                raise ValueError(f"invalid {engine} simulator trace at line {line_number}")
            actual_shape.append((identifier, len(steps)))
            phrase_passed += int(passed)
            for step_number, step in enumerate(steps, start=1):
                if not isinstance(step, dict):
                    raise ValueError(
                        f"invalid {engine} simulator step at line {line_number}:{step_number}"
                    )
                if (
                    not isinstance(step.get("passed"), bool)
                    or step.get("expectedVerdict") not in ("keep", "switch")
                    or not isinstance(step.get("actualResolved"), str)
                    or not isinstance(step.get("typed"), str)
                ):
                    raise ValueError(
                        f"invalid {engine} simulator step at line {line_number}:{step_number}"
                    )
                if step["passed"]:
                    counts["correct"] += 1
                elif step["expectedVerdict"] == "keep":
                    counts["falsePositives"] += 1
                elif step["actualResolved"] == step["typed"]:
                    counts["safeMisses"] += 1
                else:
                    counts["wrongReplacements"] += 1

    if actual_shape != expected_shape:
        raise ValueError(f"{engine} simulator traces do not match current fixtures")
    expected_summary = {
        "total": len(expected_shape),
        "passed": phrase_passed,
        "failed": len(expected_shape) - phrase_passed,
        "phraseTotal": len(expected_shape),
        "phrasePassed": phrase_passed,
    }
    if summary.get("engine") != engine:
        raise ValueError(f"{engine} simulator report has the wrong engine")
    for field, expected in expected_summary.items():
        value = summary.get(field)
        if type(value) is not int or value != expected:
            raise ValueError(
                f"{engine} simulator report field {field} is inconsistent with traces"
            )
    return summary, counts


def run_engine(engine: str) -> tuple[dict[str, object], dict[str, int]]:
    report = BUILD / f"v3.1-fresh-domain-{engine}-report.json"
    traces = BUILD / f"v3.1-fresh-domain-{engine}-traces.jsonl"
    empty = BUILD / "v3.1-fresh-domain-empty.jsonl"
    report.unlink(missing_ok=True)
    traces.unlink(missing_ok=True)
    empty.write_text("", encoding="utf-8")
    expected_shape = fixture_shape(FIXTURES)

    with tempfile.TemporaryDirectory(
        prefix=f"v3.1-fresh-domain-{engine}-",
        dir=BUILD,
    ) as temporary_directory:
        run_directory = Path(temporary_directory)
        run_report = run_directory / "report.json"
        run_traces = run_directory / "traces.jsonl"
        command = [
            "swift", "run", "-c", "release", "RuSwitcherSimulator",
            "--engine", engine, "--jobs", "8", "--input", str(empty),
            "--phrase-input", str(FIXTURES), "--output", str(run_report),
            "--phrase-results", str(run_traces),
        ]
        ranker_path = os.environ.get("V3_1_RANKER_PATH")
        if engine == "v3.1" and ranker_path:
            command.extend(["--ranker-path", ranker_path])
        completed = subprocess.run(
            command,
            cwd=ROOT,
            check=False,
            stdout=subprocess.DEVNULL,
        )
        if completed.returncode not in (0, 1):
            raise subprocess.CalledProcessError(completed.returncode, command)
        summary, counts = load_engine_outputs(
            engine,
            run_report,
            run_traces,
            expected_shape,
        )
        run_report.replace(report)
        run_traces.replace(traces)
        return summary, counts


def main() -> int:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    ensure_archive(manifest)
    phrase_count, token_count = generate(manifest)
    v3_summary, v3 = run_engine("v3")
    v31_summary, v31 = run_engine("v3.1")
    gates = {
        "falsePositives": v31["falsePositives"] == 0,
        "wrongReplacements": v31["wrongReplacements"] == 0,
        "correctTokensNotBelowV3": v31["correct"] >= v3["correct"],
        "safeMissesNotAboveV3": v31["safeMisses"] <= v3["safeMisses"],
    }
    result = {
        "sourceSHA256": sha256(ARCHIVE),
        "fixtureSHA256": sha256(FIXTURES),
        "phrases": phrase_count,
        "tokens": token_count,
        "v3": {**v3, "phrasePassed": v3_summary["phrasePassed"]},
        "v3.1": {**v31, "phrasePassed": v31_summary["phrasePassed"]},
        "gates": gates,
        "passed": all(gates.values()),
    }
    output = BUILD / "v3.1-fresh-domain-gate-report.json"
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
