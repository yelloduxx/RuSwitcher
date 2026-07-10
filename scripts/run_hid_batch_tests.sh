#!/bin/bash
set -euo pipefail

APP="/Applications/RuSwitcher.app"
BIN="$APP/Contents/MacOS/RuSwitcher"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_FIXTURE="$ROOT/Tests/Fixtures/HID/mixed-layout-corpus-batch.json"

test -x "$BIN"
pgrep -f "$BIN" >/dev/null || open "$APP"
if [ "$#" -eq 0 ]; then
    set -- "$DEFAULT_FIXTURE"
fi

python3 - "$APP" "$@" <<'PY'
import json
import os
import subprocess
import sys
import tempfile
import time

app = sys.argv[1]
fixture_paths = sys.argv[2:]
failed = False

for fixture_path in fixture_paths:
    with open(fixture_path, encoding="utf-8") as handle:
        fixture = json.load(handle)
    expected = fixture["expectedText"]
    result_path = os.path.join(
        tempfile.gettempdir(),
        f"ruswitch-hid-batch-{os.getpid()}-{fixture['name']}.json",
    )
    try:
        os.unlink(result_path)
    except FileNotFoundError:
        pass

    launched = subprocess.run(
        [
            "open", "-n", app, "--args", "--hid-probe-file", fixture_path,
            "--result", result_path,
        ],
        text=True,
        capture_output=True,
        timeout=5,
    )
    if launched.returncode != 0:
        print(f"FAIL {fixture['name']}: launch exit={launched.returncode}")
        failed = True
        continue

    typed_length = sum(len(phase["text"]) for phase in fixture["phases"])
    deadline = time.monotonic() + max(30, typed_length * 0.2)
    while not os.path.exists(result_path) and time.monotonic() < deadline:
        time.sleep(0.1)
    if not os.path.exists(result_path):
        print(f"FAIL {fixture['name']}: no result after {typed_length} input characters")
        failed = True
        continue

    with open(result_path, encoding="utf-8") as handle:
        result = json.load(handle)
    os.unlink(result_path)
    actual = result["text"]
    okay = result["postEventAccess"] and actual == expected
    print(
        f"{'PASS' if okay else 'FAIL'} {fixture['name']}: "
        f"{len(fixture['phases'])} phases, {typed_length} input chars, "
        f"sources={','.join(fixture.get('sourceIDs', []))}"
    )
    if okay:
        print(actual)
    else:
        mismatch = next(
            (index for index, pair in enumerate(zip(actual, expected)) if pair[0] != pair[1]),
            min(len(actual), len(expected)),
        )
        print(f"first mismatch at character {mismatch}")
        print(f"expected: {expected!r}")
        print(f"actual:   {actual!r}")
    failed |= not okay

raise SystemExit(1 if failed else 0)
PY
