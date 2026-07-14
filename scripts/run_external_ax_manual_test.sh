#!/bin/bash
set -euo pipefail

APP="${RUSWITCH_APP:-/Applications/RuSwitcher.app}"
APP_EXEC="$APP/Contents/MacOS/RuSwitcher"
STATUS="$(mktemp "${TMPDIR:-/tmp}/ruswitch-ax-monitor.XXXXXX.json")"
SELECTION_RESULT="$(mktemp "${TMPDIR:-/tmp}/ruswitch-ax-selection.XXXXXX.json")"
SUFFIX_RESULT="$(mktemp "${TMPDIR:-/tmp}/ruswitch-ax-suffix.XXXXXX.json")"
RESTORE_APP="${RUSWITCH_RESTORE_APP:-/Applications/RuSwitcher.app}"
WAS_RUNNING=0

test -x "$APP_EXEC"
ACTUAL_APP_SHA256="$(shasum -a 256 "$APP_EXEC" | awk '{print $1}')"
EXPECTED_APP_SHA256="${RUSWITCH_APP_SHA256:-$ACTUAL_APP_SHA256}"
if [ "$ACTUAL_APP_SHA256" != "$EXPECTED_APP_SHA256" ]; then
    echo "FAIL: candidate SHA-256 mismatch"
    exit 1
fi
echo "Testing $APP_EXEC (sha256=$ACTUAL_APP_SHA256)"
if pgrep -x RuSwitcher >/dev/null; then WAS_RUNNING=1; fi

stop_all() {
    pkill -x RuSwitcher 2>/dev/null || true
    for _ in {1..30}; do
        pgrep -x RuSwitcher >/dev/null || return 0
        sleep 0.1
    done
}

cleanup() {
    stop_all
    rm -f "$STATUS" "$SELECTION_RESULT" "$SUFFIX_RESULT"
    if [ "$WAS_RUNNING" -eq 1 ] && [ -d "$RESTORE_APP" ]; then open "$RESTORE_APP"; fi
}
trap cleanup EXIT

stop_all
rm -f "$STATUS" "$SELECTION_RESULT" "$SUFFIX_RESULT"
open -n "$APP" --args --hid-monitor "$STATUS"

MONITOR_PID="$(python3 - "$STATUS" <<'PY'
import json
import os
import sys
import time

path = sys.argv[1]
deadline = time.monotonic() + 10
while time.monotonic() < deadline:
    try:
        status = json.load(open(path, encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        time.sleep(0.02)
        continue
    if (
        status.get("monitoringActive")
        and status.get("accessibilityTrusted")
        and status.get("listenEventAccess")
        and status.get("postEventAccess")
    ):
        print(status["processID"])
        raise SystemExit(0)
    time.sleep(0.02)
raise SystemExit("FAIL external AX: monitor did not become ready")
PY
)"

open -n "$APP" --args \
    --hid-transport-probe manual-selection-double-shift \
    --result "$SELECTION_RESULT"

python3 - "$SELECTION_RESULT" "$STATUS" "$MONITOR_PID" <<'PY'
import json
import os
import sys
import time

result_path, status_path, monitor_pid = sys.argv[1:]
deadline = time.monotonic() + 15
result = None
status = None
while time.monotonic() < deadline:
    try:
        result = json.load(open(result_path, encoding="utf-8"))
        status = json.load(open(status_path, encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        time.sleep(0.02)
        continue
    if status.get("verifiedManualReplacementCount") == 1:
        break
    time.sleep(0.02)
if result is None or status is None:
    raise SystemExit("FAIL external AX selection: no result")

expected = "L|йфяцычувс|R"
replacement_start = len("L|")
replacement_length = len("йфяцычувс")
selection_is_valid = (
    (result.get("selectedRangeLocation"), result.get("selectedRangeLength"))
    in {
        (replacement_start, replacement_length),
        (replacement_start + replacement_length, 0),
    }
)
passed = (
    result.get("processID") != int(monitor_pid)
    and result.get("productionMonitoringStarted") is False
    and result.get("postEventAccess") is True
    and result.get("text") == expected
    and result.get("manualText") == expected
    and result.get("manualOutcome") == "verified-external"
    and result.get("pasteboardChangeCountDelta") == 0
    and result.get("triggerPasteboardChangeCountDelta") == 0
    and selection_is_valid
    and result.get("finalLayoutLanguage", "").lower().startswith("ru")
    and result.get("postedAutomaticReplacementCount") == 0
    and result.get("verifiedAutomaticReplacementCount") == 0
    and result.get("postedManualReplacementCount") == 0
    and result.get("verifiedManualReplacementCount") == 0
    and result.get("unexpectedInputEventCount", 0) == 0
    and not result.get("layoutMismatchStrokes")
    and not result.get("boundaryDeliveryTimeouts")
    and status.get("processID") == int(monitor_pid)
    and status.get("postedAutomaticReplacementCount") == 0
    and status.get("verifiedAutomaticReplacementCount") == 0
    and status.get("postedManualReplacementCount") == 0
    and status.get("verifiedManualReplacementCount") == 1
    and status.get("manualOutcome") == "verified"
)
print(f"{'PASS' if passed else 'FAIL'} external AX selection: result={result} monitor={status}")
raise SystemExit(0 if passed else 1)
PY

open -n "$APP" --args \
    --hid-transport-probe manual-buffer-double-shift \
    --result "$SUFFIX_RESULT"

python3 - "$SUFFIX_RESULT" "$STATUS" "$MONITOR_PID" <<'PY'
import json
import sys
import time

result_path, status_path, monitor_pid = sys.argv[1:]
deadline = time.monotonic() + 15
result = None
status = None
while time.monotonic() < deadline:
    try:
        result = json.load(open(result_path, encoding="utf-8"))
        status = json.load(open(status_path, encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        time.sleep(0.02)
        continue
    if status.get("verifiedManualReplacementCount") == 2:
        break
    time.sleep(0.02)
if result is None or status is None:
    raise SystemExit("FAIL external AX suffix: no result")

expected = "сейчас идет проверка"
passed = (
    result.get("processID") != int(monitor_pid)
    and result.get("productionMonitoringStarted") is False
    and result.get("postEventAccess") is True
    and result.get("text") == expected
    and result.get("manualText") == expected
    and result.get("manualOutcome") == "verified-external"
    and result.get("pasteboardChangeCountDelta") == 0
    and result.get("triggerPasteboardChangeCountDelta") == 0
    and result.get("selectedRangeLocation") == len(expected)
    and result.get("selectedRangeLength") == 0
    and result.get("finalLayoutLanguage", "").lower().startswith("ru")
    and result.get("postedAutomaticReplacementCount") == 0
    and result.get("verifiedAutomaticReplacementCount") == 0
    and result.get("postedManualReplacementCount") == 0
    and result.get("verifiedManualReplacementCount") == 0
    and result.get("unexpectedInputEventCount", 0) == 0
    and not result.get("layoutMismatchStrokes")
    and not result.get("boundaryDeliveryTimeouts")
    and status.get("processID") == int(monitor_pid)
    and status.get("postedAutomaticReplacementCount") == 0
    and status.get("verifiedAutomaticReplacementCount") == 0
    and status.get("postedManualReplacementCount") == 1
    and status.get("verifiedManualReplacementCount") == 2
    and status.get("manualOutcome") == "verified"
)
print(f"{'PASS' if passed else 'FAIL'} external AX suffix: result={result} monitor={status}")
raise SystemExit(0 if passed else 1)
PY
