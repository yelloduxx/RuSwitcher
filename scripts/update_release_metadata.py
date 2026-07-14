#!/usr/bin/env python3
"""Validate and transactionally update RuSwitcher release metadata."""

from __future__ import annotations

import argparse
from collections.abc import Callable, Iterable, Sequence
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import tempfile


SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
CRITICAL_JSON_KEYS = frozenset(("version", "build", "sha256"))
CASK_VERSION_PATTERN = re.compile(r'^(\s*version ")[^"]*(".*)$', re.MULTILINE)
CASK_SHA256_PATTERN = re.compile(r'^(\s*sha256 ")[^"]*(".*)$', re.MULTILINE)


class TransactionInterrupted(RuntimeError):
    def __init__(self, signum: int) -> None:
        super().__init__(f"release metadata transaction interrupted by signal {signum}")
        self.signum = signum


def _reject_duplicate_release_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result and key in CRITICAL_JSON_KEYS:
            raise ValueError(f"version.json contains duplicate {key!r} declarations")
        result[key] = value
    return result


def prepare_release_metadata(
    version_json: Path,
    cask: Path,
    *,
    version: str,
    build: int,
    sha256: str,
) -> tuple[bytes, bytes]:
    """Validate current files and return their complete replacement contents."""
    if not SHA256_PATTERN.fullmatch(sha256):
        raise ValueError("sha256 must be 64 lowercase hexadecimal characters")
    if build <= 0:
        raise ValueError("build must be positive")

    original_version = version_json.read_bytes()
    original_cask = cask.read_bytes()
    metadata = json.loads(
        original_version,
        object_pairs_hook=_reject_duplicate_release_keys,
    )
    if not isinstance(metadata, dict):
        raise ValueError("version.json must contain a JSON object")
    missing = CRITICAL_JSON_KEYS.difference(metadata)
    if missing:
        raise ValueError(
            "version.json is missing release fields: " + ", ".join(sorted(missing))
        )
    try:
        current_build = int(metadata["build"])
    except (TypeError, ValueError) as error:
        raise ValueError("version.json build must be an integer") from error
    if metadata["version"] != version or current_build != build:
        raise ValueError("version.json changed while the release was being built")

    metadata["sha256"] = sha256
    updated_version = (json.dumps(metadata, indent=2) + "\n").encode()

    cask_text = original_cask.decode()
    version_matches = list(CASK_VERSION_PATTERN.finditer(cask_text))
    sha_matches = list(CASK_SHA256_PATTERN.finditer(cask_text))
    if len(version_matches) != 1 or len(sha_matches) != 1:
        raise ValueError("cask must contain exactly one version and sha256 declaration")
    updated_cask = CASK_VERSION_PATTERN.sub(
        lambda match: f'{match.group(1)}{version}{match.group(2)}',
        cask_text,
        count=1,
    )
    updated_cask = CASK_SHA256_PATTERN.sub(
        lambda match: f'{match.group(1)}{sha256}{match.group(2)}',
        updated_cask,
        count=1,
    )
    return updated_version, updated_cask.encode()


def stage_bytes_for_replacement(path: Path, data: bytes) -> Path:
    """Write a sibling staging file with the destination's current mode."""
    path = path.resolve()
    mode = stat.S_IMODE(path.stat().st_mode)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.release-",
        dir=path.parent,
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        temporary.unlink(missing_ok=True)
        raise
    return temporary


def _backup_target(path: Path) -> Path | None:
    if not path.exists():
        return None
    descriptor, backup_name = tempfile.mkstemp(
        prefix=f".{path.name}.rollback-",
        dir=path.parent,
    )
    os.close(descriptor)
    backup = Path(backup_name)
    backup.unlink()
    try:
        os.link(path, backup)
    except OSError:
        shutil.copy2(path, backup)
    return backup


def _fsync_directories(paths: Iterable[Path]) -> None:
    for directory in {path.resolve() for path in paths}:
        descriptor = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


def replace_files_transactionally(
    replacements: Sequence[tuple[Path, Path]],
    *,
    after_replace: Callable[[int, Path], None] | None = None,
) -> None:
    """Replace several files as one rollback-aware signal-safe transaction.

    Each tuple is ``(staged_source, destination)``. Staged files are consumed
    on success. On a handled error, SIGINT, or SIGTERM every destination is
    restored to its exact pre-transaction contents and mode.
    """
    normalized = [
        (source.resolve(), destination.resolve())
        for source, destination in replacements
    ]
    if not normalized:
        raise ValueError("at least one replacement is required")
    destinations = [destination for _, destination in normalized]
    if len(set(destinations)) != len(destinations):
        raise ValueError("replacement destinations must be unique")
    for source, destination in normalized:
        if source == destination:
            raise ValueError("staged source and destination must differ")
        if not source.is_file():
            raise ValueError(f"staged replacement does not exist: {source}")
        if not destination.parent.is_dir():
            raise ValueError(f"destination directory does not exist: {destination.parent}")

    backups: list[tuple[Path, Path | None]] = []
    try:
        for destination in destinations:
            backups.append((destination, _backup_target(destination)))
    except BaseException:
        for _, backup in backups:
            if backup is not None:
                backup.unlink(missing_ok=True)
        raise
    previous_handlers: dict[signal.Signals, signal.Handlers] = {}

    def interrupted(signum: int, _frame: object) -> None:
        raise TransactionInterrupted(signum)

    try:
        for current_signal in (signal.SIGINT, signal.SIGTERM):
            previous_handlers[current_signal] = signal.getsignal(current_signal)
            signal.signal(current_signal, interrupted)

        for index, (source, destination) in enumerate(normalized):
            os.replace(source, destination)
            _fsync_directories((destination.parent,))
            if after_replace is not None:
                after_replace(index, destination)
    except BaseException:
        for current_signal in (signal.SIGINT, signal.SIGTERM):
            signal.signal(current_signal, signal.SIG_IGN)
        rollback_errors: list[OSError] = []
        for destination, backup in reversed(backups):
            try:
                if backup is None:
                    destination.unlink(missing_ok=True)
                else:
                    os.replace(backup, destination)
            except OSError as error:
                rollback_errors.append(error)
        _fsync_directories(destination.parent for destination in destinations)
        if rollback_errors:
            detail = "; ".join(str(error) for error in rollback_errors)
            raise RuntimeError(f"release rollback failed: {detail}")
        raise
    finally:
        for current_signal, previous in previous_handlers.items():
            signal.signal(current_signal, previous)
        for _, backup in backups:
            if backup is not None:
                backup.unlink(missing_ok=True)


def update_release_metadata(
    version_json: Path,
    cask: Path,
    *,
    version: str,
    build: int,
    sha256: str,
    _after_replace: Callable[[int, Path], None] | None = None,
) -> None:
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
        # The cask is secondary metadata; version.json is the release manifest
        # and is deliberately committed last.
        replace_files_transactionally(
            ((staged_cask, cask), (staged_version, version_json)),
            after_replace=_after_replace,
        )
    finally:
        staged_version.unlink(missing_ok=True)
        staged_cask.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version-json", type=Path, required=True)
    parser.add_argument("--cask", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--sha256", required=True)
    args = parser.parse_args()
    update_release_metadata(
        args.version_json,
        args.cask,
        version=args.version,
        build=args.build,
        sha256=args.sha256,
    )


if __name__ == "__main__":
    main()
