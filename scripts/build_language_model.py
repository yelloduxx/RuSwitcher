#!/usr/bin/env python3
"""Build the deterministic, local RuSwitcher language model.

The checked-in artifact is generated from pinned CC BY 3.0 Google Books
frequency lists. Runtime code never downloads data.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import struct
import urllib.request
from collections import Counter
from pathlib import Path


REVISION = "e20471c15a758be3362b16d07870b34df4f7ccc3"
BASE_URL = f"https://raw.githubusercontent.com/orgtre/google-books-ngram-frequency/{REVISION}/"
SOURCES = {
    "ngrams/1grams_russian.csv": "13be6573713588cb4b52fbf6d10490791e938f025b6cb6b96fb9a16a96f5b04c",
    "ngrams/1grams_english.csv": "f7f63aa08f0bb2f7f654cddff3a7ced4968b27887b2c0e7cd4b4d108221e197d",
    "ngrams/2grams_russian.csv": "882c98e94dfc4c4ae16cc57f495cc9ceb74d2c8963a926520f4b0bcaed7f17d8",
    "ngrams/2grams_english.csv": "9e2ae9e6149785a078e62325d468e462974ce6eb94eefe8f27b16e6d011e8ee5",
    "ngrams/3grams_russian.csv": "6c195471e1ade65541eb64db0d7c1b9603baa3968f50a9759ba04a610075e26c",
    "ngrams/3grams_english.csv": "6cfdd4cc65cbd0df606d174df00274843c81eb430cfbeddce4711fb07f4e12df",
}

SECTION = {
    "metadata": 1,
    "ru_words": 2,
    "en_words": 3,
    "ru_chars": 4,
    "en_chars": 5,
    "ru_bigrams": 6,
    "en_bigrams": 7,
    "ru_trigrams": 8,
    "en_trigrams": 9,
    "productive": 10,
    "thresholds": 11,
}

PRODUCTIVE_RU = [
    "авиа", "авто", "агро", "аэро", "био", "видео", "гипер", "инфо",
    "кибер", "макро", "мега", "микро", "мини", "мото", "мульти", "нано",
    "нейро", "псевдо", "радио", "ретро", "супер", "теле", "ультра", "фото",
    "экзо", "эко", "электро",
]

# Conservative colloquial/morphological endings. The leading marker keeps
# suffixes distinguishable from productive prefixes in the compact section.
PRODUCTIVE_RU_SUFFIXES = [
    "ульки", "юшки", "ушки", "оньки", "еньки", "очки", "ечки",
]

CURATED_RU = [
    "супер", "спина", "привет", "приветствую", "раскладка",
    "автоконверсия", "контекст", "контекстный", "нейросеть", "флоуменеджер",
]
CURATED_EN = ["plan", "hello", "layout", "context", "keyboard", "super", "spine"]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_path(relative: str, source_dir: Path | None, cache_dir: Path) -> Path:
    path = (source_dir / relative) if source_dir else (cache_dir / relative)
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        if source_dir:
            raise FileNotFoundError(path)
        print(f"download {relative}")
        urllib.request.urlretrieve(BASE_URL + relative, path)
    expected = SOURCES[relative]
    actual = sha256(path)
    if actual != expected:
        raise RuntimeError(f"SHA-256 mismatch for {relative}: {actual} != {expected}")
    return path


def is_language_word(word: str, language: str) -> bool:
    if not 1 <= len(word) <= 40 or word != word.lower():
        return False
    letters = [char for char in word if char.isalpha()]
    if len(letters) != len(word):
        return False
    if language == "ru":
        return all("а" <= char <= "я" or char == "ё" for char in letters)
    return all("a" <= char <= "z" for char in letters)


def read_words(path: Path, language: str, curated: list[str]) -> dict[str, float]:
    frequencies: dict[str, int] = {}
    with path.open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            word = row["ngram"].strip().lower()
            if is_language_word(word, language):
                frequencies[word] = int(row["freq"])
    floor = max(1, min(frequencies.values(), default=1))
    for index, word in enumerate(curated):
        frequencies.setdefault(word, floor * max(2, len(curated) - index))
    peak = max(frequencies.values())
    return {word: round(math.log(freq / peak), 6) for word, freq in frequencies.items()}


def character_model(words: dict[str, float], limit: int = 30000) -> dict[str, float]:
    counts: Counter[str] = Counter()
    for word, log_frequency in words.items():
        weight = max(1, int(10000 * math.exp(log_frequency)))
        padded = "^" + word + "$"
        for size in range(2, 6):
            for index in range(0, len(padded) - size + 1):
                counts[padded[index:index + size]] += weight
    selected = counts.most_common(limit)
    total = sum(count for _, count in selected) or 1
    return {gram: round(math.log(count / total), 6) for gram, count in selected}


def read_phrases(path: Path, language: str, order: int) -> dict[str, float]:
    values: dict[str, int] = {}
    with path.open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            words = [part.lower() for part in row["ngram"].split()]
            if len(words) != order or not all(is_language_word(word, language) for word in words):
                continue
            values["\u001f".join(words)] = int(row["freq"])
    peak = max(values.values(), default=1)
    return {phrase: round(math.log(freq / peak), 6) for phrase, freq in values.items()}


def json_bytes(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def fnv1a64(data: bytes) -> int:
    value = 0xCBF29CE484222325
    for byte in data:
        value ^= byte
        value = (value * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return value


def write_model(output: Path, sections: list[tuple[int, bytes]]) -> None:
    payload = b"".join(data for _, data in sections)
    directory_size = len(sections) * 12
    header = struct.pack("<4sHHIQ", b"RSLM", 1, len(sections), len(payload), fnv1a64(payload))
    offset = 0
    directory = bytearray()
    for kind, data in sections:
        directory.extend(struct.pack("<HHII", kind, 0, offset, len(data)))
        offset += len(data)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(header + bytes(directory) + payload)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", type=Path)
    parser.add_argument("--cache-dir", type=Path, default=Path(".build/language-model-source"))
    parser.add_argument("--output", type=Path, default=Path("Sources/RuSwitcherCore/Resources/language-model-v1.bin"))
    args = parser.parse_args()

    paths = {key: source_path(key, args.source_dir, args.cache_dir) for key in SOURCES}
    ru_words = read_words(paths["ngrams/1grams_russian.csv"], "ru", CURATED_RU)
    en_words = read_words(paths["ngrams/1grams_english.csv"], "en", CURATED_EN)
    metadata = {
        "formatVersion": 1,
        "modelVersion": "2026.07-v3-oov2",
        "source": "orgtre/google-books-ngram-frequency",
        "sourceRevision": REVISION,
        "license": "CC BY 3.0",
        "wordCounts": {"ru": len(ru_words), "en": len(en_words)},
    }
    thresholds = {
        "short": 3.0,
        "russianContext": 1.15,
        "neutral": 2.2,
        "englishContext": 3.8,
        "russianOOVNeutral": 1.55,
        "russianOOVEnglishLong": 3.2,
        "compoundBonus": 4.8,
        "confirmedBonus": 20.0,
    }
    values = {
        "metadata": metadata,
        "ru_words": ru_words,
        "en_words": en_words,
        "ru_chars": character_model(ru_words),
        "en_chars": character_model(en_words),
        "ru_bigrams": read_phrases(paths["ngrams/2grams_russian.csv"], "ru", 2),
        "en_bigrams": read_phrases(paths["ngrams/2grams_english.csv"], "en", 2),
        "ru_trigrams": read_phrases(paths["ngrams/3grams_russian.csv"], "ru", 3),
        "en_trigrams": read_phrases(paths["ngrams/3grams_english.csv"], "en", 3),
        "productive": PRODUCTIVE_RU + ["-" + suffix for suffix in PRODUCTIVE_RU_SUFFIXES],
        "thresholds": thresholds,
    }
    write_model(args.output, [(SECTION[name], json_bytes(values[name])) for name in SECTION])
    print(f"wrote {args.output} ({args.output.stat().st_size} bytes, sha256={sha256(args.output)})")


if __name__ == "__main__":
    main()
