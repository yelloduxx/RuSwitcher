#!/bin/bash
set -euo pipefail

APP="${RUSWITCH_APP:-/Applications/RuSwitcher.app}"
APP_EXEC="$APP/Contents/MacOS/RuSwitcher"
RESULT="$(mktemp "${TMPDIR:-/tmp}/ruswitch-reconversion.XXXXXX.json")"
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

cleanup() {
    pkill -x RuSwitcher 2>/dev/null || true
    rm -f "$RESULT"
    if [ "$WAS_RUNNING" -eq 1 ]; then open "$APP"; fi
}
trap cleanup EXIT

pkill -x RuSwitcher 2>/dev/null || true
for _ in {1..30}; do
    pgrep -x RuSwitcher >/dev/null || break
    sleep 0.1
done

open -n "$APP" --args \
    --hid-probe manual-auto-reconvert-double-shift \
    --result "$RESULT"

python3 - "$RESULT" <<'PY'
import json
import os
import sys
import time

path = sys.argv[1]
deadline = time.monotonic() + 15
while (not os.path.exists(path) or os.path.getsize(path) == 0) and time.monotonic() < deadline:
    time.sleep(0.05)
if not os.path.exists(path) or os.path.getsize(path) == 0:
    raise SystemExit("FAIL manual reconversion: no result")

result = json.load(open(path, encoding="utf-8"))
expected = "сейчас ghjdthrf "
passed = (
    result.get("postEventAccess") is True
    and result.get("text") == expected
    and result.get("manualText") == expected
    and result.get("manualOutcome") == "verified"
    and result.get("postedAutomaticReplacementCount") == 1
    and result.get("verifiedAutomaticReplacementCount") == 1
    and result.get("postedManualReplacementCount") == 1
    and result.get("verifiedManualReplacementCount") == 1
    and result.get("adaptiveBias") == -2.5
    and result.get("pasteboardChangeCountDelta") == 0
    and result.get("triggerPasteboardChangeCountDelta") == 0
    and result.get("selectedRangeLocation") == len(expected)
    and result.get("selectedRangeLength") == 0
    and result.get("finalLayoutLanguage", "").lower().startswith("en")
    and result.get("unexpectedInputEventCount", 0) == 0
    and not result.get("layoutMismatchStrokes")
    and not result.get("boundaryDeliveryTimeouts")
)
print(f"{'PASS' if passed else 'FAIL'} manual auto-reconversion: {result}")
raise SystemExit(0 if passed else 1)
PY
