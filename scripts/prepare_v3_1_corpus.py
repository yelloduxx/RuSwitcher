#!/usr/bin/env python3
"""Prepare independent RuSwitcher V3.1 train/validation/test sentence sets.

The split is computed from normalized source sentence pairs before synthetic
keyboard errors are generated. Test output is never consumed by the trainer.
Only aggregate test metrics should be published.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import itertools
import json
import os
import shutil
import tempfile
import unicodedata
import urllib.request
import zipfile
from pathlib import Path
from typing import TextIO


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = ROOT / "scripts/v3_1_training_sources.json"
DEFAULT_ARCHIVE = ROOT / ".build/corpora/Tatoeba-v2023-04-12-en-ru.txt.zip"
DEFAULT_OUTPUT = ROOT / ".build/v3.1-corpus"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize(text: str) -> str:
    return unicodedata.normalize("NFC", " ".join(text.split()))


def valid_sentence(text: str, language: str) -> bool:
    if not 2 <= len(text) <= 384 or len(text.encode("utf-8")) > 768:
        return False
    if any(unicodedata.category(char) in {"Cc", "Cs"} for char in text):
        return False
    lowered = text.lower()
    if language == "en":
        return any("a" <= char <= "z" for char in lowered)
    return any("а" <= char <= "я" or char == "ё" for char in lowered)


def pair_digest(salt: str, english: str, russian: str) -> bytes:
    value = f"{salt}\0{english}\0{russian}".encode("utf-8")
    return hashlib.sha256(value).digest()


def content_digest(english: str, russian: str) -> bytes:
    return hashlib.sha256(f"{english}\0{russian}".encode("utf-8")).digest()


def split_name(digest: bytes, split: dict[str, object]) -> str:
    bucket = int.from_bytes(digest[:8], "big") % 100
    train = split["trainBuckets"]
    validation = split["validationBuckets"]
    test = split["testBuckets"]
    assert isinstance(train, list) and isinstance(validation, list) and isinstance(test, list)
    if int(train[0]) <= bucket <= int(train[1]):
        return "train"
    if int(validation[0]) <= bucket <= int(validation[1]):
        return "validation"
    if int(test[0]) <= bucket <= int(test[1]):
        return "test"
    raise ValueError(f"bucket {bucket} is not assigned")


def is_quarantined(english: str, russian: str, split: dict[str, object]) -> bool:
    quarantines = split.get("quarantines", [])
    if not isinstance(quarantines, list):
        raise ValueError("split.quarantines must be a list")
    for quarantine in quarantines:
        if not isinstance(quarantine, dict):
            raise ValueError("every quarantine must be an object")
        buckets = quarantine.get("buckets")
        if not isinstance(buckets, list) or len(buckets) != 2:
            raise ValueError("quarantine buckets must be a two-item range")
        digest = pair_digest(str(quarantine["salt"]), english, russian)
        bucket = int.from_bytes(digest[:8], "big") % 100
        if int(buckets[0]) <= bucket <= int(buckets[1]):
            return True
    return False


def open_parallel(archive: zipfile.ZipFile, entry: str) -> TextIO:
    return io.TextIOWrapper(archive.open(entry), encoding="utf-8", errors="strict", newline="")


def prepare(manifest: dict[str, object], archive_path: Path, output_dir: Path, max_pairs: int | None) -> dict[str, object]:
    corpus = manifest["sentenceCorpus"]
    split = manifest["split"]
    assert isinstance(corpus, dict) and isinstance(split, dict)
    expected_hash = str(corpus["sha256"])
    actual_hash = sha256_file(archive_path)
    if actual_hash != expected_hash:
        raise ValueError(f"archive SHA-256 mismatch: {actual_hash} != {expected_hash}")

    output_dir.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix="v3.1-corpus-", dir=output_dir.parent))
    split_names = ("train", "validation", "test", "quarantine")
    handles = {name: (temporary / f"{name}.jsonl").open("w", encoding="utf-8", newline="\n") for name in split_names}
    counts = {name: 0 for name in split_names}
    rejected = 0
    duplicates = 0
    seen: set[bytes] = set()
    try:
        with zipfile.ZipFile(archive_path) as archive:
            english_entry = str(corpus["englishEntry"])
            russian_entry = str(corpus["russianEntry"])
            names = set(archive.namelist())
            if english_entry not in names or russian_entry not in names:
                raise ValueError("parallel corpus entries are missing from archive")
            with open_parallel(archive, english_entry) as english_file, open_parallel(archive, russian_entry) as russian_file:
                parallel = itertools.zip_longest(english_file, russian_file)
                for line_number, pair in enumerate(parallel, start=1):
                    if pair[0] is None or pair[1] is None:
                        raise ValueError("parallel corpus files have different line counts")
                    english = normalize(pair[0])
                    russian = normalize(pair[1])
                    if not valid_sentence(english, "en") or not valid_sentence(russian, "ru"):
                        rejected += 1
                        continue
                    identity = content_digest(english, russian)
                    if identity in seen:
                        duplicates += 1
                        continue
                    seen.add(identity)
                    if is_quarantined(english, russian, split):
                        target = "quarantine"
                    else:
                        assignment = pair_digest(str(split["salt"]), english, russian)
                        target = split_name(assignment, split)
                    record = {
                        "id": identity.hex(),
                        "source": str(corpus["name"]),
                        "sourceLine": line_number,
                        "en": english,
                        "ru": russian,
                    }
                    handles[target].write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
                    counts[target] += 1
                    if max_pairs is not None and sum(counts.values()) >= max_pairs:
                        break
        for handle in handles.values():
            handle.flush()
            os.fsync(handle.fileno())
            handle.close()
        output_hashes = {name: sha256_file(temporary / f"{name}.jsonl") for name in counts}
        summary = {
            "protocolVersion": manifest["protocolVersion"],
            "sourceSHA256": actual_hash,
            "counts": counts,
            "rejected": rejected,
            "duplicates": duplicates,
            "outputSHA256": output_hashes,
            "testPolicy": "held out; never fit features, weights, calibration, or thresholds",
        }
        (temporary / "summary.json").write_text(
            json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        for name in (*counts.keys(), "summary"):
            source = temporary / f"{name}.jsonl" if name != "summary" else temporary / "summary.json"
            os.replace(source, output_dir / source.name)
        return summary
    finally:
        for handle in handles.values():
            if not handle.closed:
                handle.close()
        shutil.rmtree(temporary, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--archive", type=Path, default=DEFAULT_ARCHIVE)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--max-pairs", type=int)
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    corpus = manifest["sentenceCorpus"]
    if not args.archive.exists():
        if not args.download:
            raise FileNotFoundError(f"missing {args.archive}; pass --download to fetch the pinned snapshot")
        args.archive.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(corpus["url"]) as response, args.archive.open("wb") as output:
            shutil.copyfileobj(response, output)

    summary = prepare(manifest, args.archive, args.output_dir, args.max_pairs)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
