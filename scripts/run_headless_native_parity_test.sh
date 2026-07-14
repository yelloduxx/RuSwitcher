#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="${1:-$ROOT/Tests/Fixtures/HID/headless-native-parity-trap.json}"
APP="${RUSWITCH_APP:-/Applications/RuSwitcher.app}"
APP_EXEC="$APP/Contents/MacOS/RuSwitcher"
HEADLESS="$ROOT/.build/headless-native-parity-headless.json"
NATIVE="$ROOT/.build/headless-native-parity-native.json"
WAS_RUNNING=0

if pgrep -x RuSwitcher >/dev/null; then WAS_RUNNING=1; fi
test -x "$APP_EXEC"
ACTUAL_APP_SHA256="$(shasum -a 256 "$APP_EXEC" | awk '{print $1}')"
EXPECTED_APP_SHA256="${RUSWITCH_APP_SHA256:-$ACTUAL_APP_SHA256}"
if [ "$ACTUAL_APP_SHA256" != "$EXPECTED_APP_SHA256" ]; then
    echo "FAIL: candidate SHA-256 mismatch"
    exit 1
fi
echo "Testing $APP_EXEC (sha256=$ACTUAL_APP_SHA256)"

restore_application() {
    if [ "$WAS_RUNNING" -eq 1 ]; then
        open "$APP"
        for _ in {1..30}; do
            pgrep -x RuSwitcher >/dev/null && return
            sleep 0.1
        done
        echo "WARNING: normal RuSwitcher process did not restart" >&2
    fi
}
trap restore_application EXIT

cd "$ROOT"
swift run -c release RuSwitcherTypingSimulator \
    --input "$FIXTURE" \
    --output "$HEADLESS" >/dev/null

KEEP_HID_RESULTS=1 \
HID_RESULT_PATH="$NATIVE" \
HID_RESTART_SETTLE_SECONDS=1 \
RUSWITCH_APP="$APP" \
    bash "$ROOT/scripts/run_hid_batch_tests.sh" "$FIXTURE"

python3 - "$FIXTURE" "$HEADLESS" "$NATIVE" <<'PY'
import json
import sys

fixture_path, headless_path, native_path = sys.argv[1:]
fixture = json.load(open(fixture_path, encoding="utf-8"))
headless = json.load(open(headless_path, encoding="utf-8"))
native = json.load(open(native_path, encoding="utf-8"))

expected = fixture["expectedText"]
expected_transactions = fixture["expectedTransactions"]
checks = {
    "headlessTextMatches": headless["actualText"] == expected,
    "nativeTextMatches": native["text"] == expected,
    "headlessEqualsNative": headless["actualText"] == native["text"],
    "headlessTransactionsMatch": headless["transactionCount"] == expected_transactions,
    "nativePostedTransactionsMatch": native["postedAutomaticReplacementCount"] == expected_transactions,
    "nativeVerifiedTransactionsMatch": native["verifiedAutomaticReplacementCount"] == expected_transactions,
    "nativeCanPostEvents": native["postEventAccess"],
    "nativePasteboardUntouched": native.get("pasteboardChangeCountDelta") == 0,
    "nativeHadNoExternalInput": native.get("unexpectedInputEventCount", 0) == 0,
    "nativeLayoutStayedSynchronized": not native["layoutMismatchStrokes"],
    "nativeBoundariesDelivered": not native["boundaryDeliveryTimeouts"],
}

summary = {
    "fixture": fixture["name"],
    "passed": all(checks.values()),
    "expectedText": expected,
    "headlessActualText": headless["actualText"],
    "nativeActualText": native["text"],
    "expectedTransactions": expected_transactions,
    "headlessTransactions": headless["transactionCount"],
    "nativePostedTransactions": native["postedAutomaticReplacementCount"],
    "nativeVerifiedTransactions": native["verifiedAutomaticReplacementCount"],
    "checks": checks,
}
print(json.dumps(summary, ensure_ascii=False, indent=2))
raise SystemExit(0 if summary["passed"] else 1)
PY
