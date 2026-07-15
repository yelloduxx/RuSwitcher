#!/bin/bash
set -euo pipefail

APP="${RUSWITCH_APP:-/Applications/RuSwitcher.app}"
APP_EXEC="$APP/Contents/MacOS/RuSwitcher"
ORIGINAL_APP="/Applications/RuSwitcher.app"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ruswitch-toggle-cycle.XXXXXX")"
WAS_RUNNING=0

test -x "$APP_EXEC"
if pgrep -x RuSwitcher >/dev/null; then WAS_RUNNING=1; fi

cleanup() {
    pkill -x RuSwitcher 2>/dev/null || true
    rm -rf "$WORK_DIR"
    if [ "$WAS_RUNNING" -eq 1 ]; then open "$ORIGINAL_APP"; fi
}
trap cleanup EXIT

run_scenario() {
    local name="$1"
    local force_fallback="${2:-0}"
    local result="$WORK_DIR/$name.json"
    pkill -x RuSwitcher 2>/dev/null || true
    for _ in {1..30}; do
        pgrep -x RuSwitcher >/dev/null || break
        sleep 0.1
    done
    if [ "$force_fallback" -eq 1 ]; then
        open -n "$APP" --args --hid-probe "$name" --result "$result" \
            --force-transient-paste-fallback
    else
        open -n "$APP" --args --hid-probe "$name" --result "$result"
    fi
    python3 - "$result" <<'PY'
import os
import sys
import time

path = sys.argv[1]
deadline = time.monotonic() + 20
while (not os.path.exists(path) or os.path.getsize(path) == 0) and time.monotonic() < deadline:
    time.sleep(0.05)
if not os.path.exists(path) or os.path.getsize(path) == 0:
    raise SystemExit(f"FAIL: no result for {os.path.basename(path)}")
PY
}

run_scenario manual-russian-word-toggle-cycle 1
run_scenario manual-selection-toggle-cycle
run_scenario manual-auto-word-toggle-cycle

python3 - "$WORK_DIR" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
expected = {
    "manual-russian-word-toggle-cycle": [";jgf", "жопа"],
    "manual-selection-toggle-cycle": ["руку", "here", "руку", "here"],
    "manual-auto-word-toggle-cycle": ["ckj;yj ", "сложно "],
}

for name, trace in expected.items():
    result = json.loads((root / f"{name}.json").read_text(encoding="utf-8"))
    passed = (
        result.get("postEventAccess") is True
        and result.get("manualTrace") == trace
        and result.get("text") == trace[-1]
        and result.get("pasteboardChangeCountDelta") == 0
        and result.get("unexpectedInputEventCount") == 0
        and not result.get("layoutMismatchStrokes")
        and not result.get("boundaryDeliveryTimeouts")
    )
    if name == "manual-auto-word-toggle-cycle":
        passed = passed and result.get("postedAutomaticReplacementCount") == 1
    print(f"{'PASS' if passed else 'FAIL'} {name}: {result.get('manualTrace')!r}")
    if not passed:
        raise SystemExit(1)
PY
