#!/usr/bin/env python3
"""Publish a verified DMG and its metadata as one rollback-aware transaction."""

from __future__ import annotations

import argparse
from collections.abc import Callable
import hashlib
from pathlib import Path

from update_release_metadata import (
    prepare_release_metadata,
    replace_files_transactionally,
    stage_bytes_for_replacement,
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def publish_release(
    candidate_dmg: Path,
    destination_dmg: Path,
    version_json: Path,
    cask: Path,
    *,
    version: str,
    build: int,
    sha256: str,
    _after_replace: Callable[[int, Path], None] | None = None,
) -> None:
    candidate_dmg = candidate_dmg.resolve()
    destination_dmg = destination_dmg.resolve()
    if candidate_dmg == destination_dmg:
        raise ValueError("candidate and destination DMG paths must differ")
    if not candidate_dmg.is_file():
        raise ValueError(f"candidate DMG does not exist: {candidate_dmg}")
    if _sha256(candidate_dmg) != sha256:
        raise ValueError("candidate DMG sha256 does not match release metadata")

    updated_version, updated_cask = prepare_release_metadata(
        version_json,
        cask,
        version=version,
        build=build,
        sha256=sha256,
    )
    staged_version = stage_bytes_for_replacement(version_json, updated_version)
    try:
        staged_cask = stage_bytes_for_replacement(cask, updated_cask)
    except BaseException:
        staged_version.unlink(missing_ok=True)
        raise
    try:
        # Publish the payload first and the externally consumed manifest last.
        replace_files_transactionally(
            (
                (candidate_dmg, destination_dmg),
                (staged_cask, cask),
                (staged_version, version_json),
            ),
            after_replace=_after_replace,
        )
    finally:
        staged_version.unlink(missing_ok=True)
        staged_cask.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate-dmg", type=Path, required=True)
    parser.add_argument("--destination-dmg", type=Path, required=True)
    parser.add_argument("--version-json", type=Path, required=True)
    parser.add_argument("--cask", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--sha256", required=True)
    args = parser.parse_args()
    publish_release(
        args.candidate_dmg,
        args.destination_dmg,
        args.version_json,
        args.cask,
        version=args.version,
        build=args.build,
        sha256=args.sha256,
    )


if __name__ == "__main__":
    main()
