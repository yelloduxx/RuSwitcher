#!/bin/bash
set -euo pipefail

APP="${RUSWITCH_APP:-/Applications/RuSwitcher.app}"
APP_EXEC="$APP/Contents/MacOS/RuSwitcher"
if [ ! -x "$APP_EXEC" ]; then
    echo "FAIL: RuSwitcher executable not found at $APP_EXEC"
    exit 1
fi
ACTUAL_APP_SHA256=$(shasum -a 256 "$APP_EXEC" | awk '{print $1}')
EXPECTED_APP_SHA256="${RUSWITCH_APP_SHA256:-$ACTUAL_APP_SHA256}"
if [ "$ACTUAL_APP_SHA256" != "$EXPECTED_APP_SHA256" ]; then
    echo "FAIL: candidate SHA-256 mismatch"
    exit 1
fi
echo "Testing $APP_EXEC (sha256=$ACTUAL_APP_SHA256)"
DOMAIN="com.ruswitcher.app"
BACKUP="$(mktemp "${TMPDIR:-/tmp}/ruswitch-prefs.XXXXXX.plist")"
RESULT="$(mktemp "${TMPDIR:-/tmp}/ruswitch-learning.XXXXXX.json")"
BASELINE_RESULT="$(mktemp "${TMPDIR:-/tmp}/ruswitch-learning-baseline.XXXXXX.json")"
PERSISTED_RESULT="$(mktemp "${TMPDIR:-/tmp}/ruswitch-learning-persisted.XXXXXX.json")"
BUFFER_RESULT="$(mktemp "${TMPDIR:-/tmp}/ruswitch-buffer-trigger.XXXXXX.json")"
PREVIOUS_RESULT="$(mktemp "${TMPDIR:-/tmp}/ruswitch-previous-trigger.XXXXXX.json")"
FIXTURE="$(mktemp "${TMPDIR:-/tmp}/ruswitch-learning-fixture.XXXXXX.json")"

defaults export "$DOMAIN" "$BACKUP" >/dev/null

restart_app() {
    pkill -x RuSwitcher 2>/dev/null || true
    for _ in {1..20}; do
        pgrep -x RuSwitcher >/dev/null || break
        sleep 0.1
    done
    sleep 0.3
    open "$APP"
    for _ in {1..30}; do
        pgrep -f "$APP/Contents/MacOS/RuSwitcher" >/dev/null && return
        sleep 0.1
    done
    return 1
}

stop_app() {
    pkill -x RuSwitcher 2>/dev/null || true
    for _ in {1..20}; do
        pgrep -x RuSwitcher >/dev/null || return 0
        sleep 0.1
    done
    return 0
}

restore_preferences() {
    pkill -x RuSwitcher 2>/dev/null || true
    defaults import "$DOMAIN" "$BACKUP" >/dev/null
    rm -f "$BACKUP" "$RESULT" "$BASELINE_RESULT" "$PERSISTED_RESULT" "$BUFFER_RESULT" "$PREVIOUS_RESULT" "$FIXTURE"
    restart_app || true
}
trap restore_preferences EXIT

defaults write "$DOMAIN" com.ruswitcher.autoSwitch -bool true
defaults write "$DOMAIN" com.ruswitcher.autoConvert -bool true
defaults write "$DOMAIN" com.ruswitcher.triggerKey -string shift
defaults write "$DOMAIN" com.ruswitcher.triggerDoubleTap -bool true
defaults delete "$DOMAIN" com.ruswitcher.adaptiveRules.v1 2>/dev/null || true

printf '%s\n' \
    '{"name":"manual-learning-rule-check","phases":[{"sourceLanguage":"en","text":"qazwsxedc "}]}' \
    >"$FIXTURE"

stop_app

open -n "$APP" --args \
    --hid-probe manual-previous-word-double-shift \
    --hid-use-standard-preferences \
    --result "$PREVIOUS_RESULT"

python3 - "$PREVIOUS_RESULT" <<'PY'
import json
import os
import sys
import time

path = sys.argv[1]
deadline = time.monotonic() + 15
while (not os.path.exists(path) or os.path.getsize(path) == 0) and time.monotonic() < deadline:
    time.sleep(0.1)
if not os.path.exists(path) or os.path.getsize(path) == 0:
    raise SystemExit("FAIL manual-previous-word-double-shift: no result")
with open(path, encoding="utf-8") as handle:
    result = json.load(handle)
expected = "сейчас идет проверка "
passed = (
    result["postEventAccess"]
    and result["text"] == expected
    and result.get("manualText") == expected
    and result.get("pasteboardChangeCountDelta") == 0
    and result.get("triggerPasteboardChangeCountDelta") == 0
    and result.get("manualOutcome") == "verified"
    and result.get("postedManualReplacementCount") == 1
    and result.get("verifiedManualReplacementCount") == 1
    and result.get("postedAutomaticReplacementCount") == 0
    and result.get("verifiedAutomaticReplacementCount") == 0
    and result.get("finalLayoutLanguage", "").lower().startswith("ru")
    and not result.get("boundaryDeliveryTimeouts")
)
print(f"{'PASS' if passed else 'FAIL'} manual-previous-word-double-shift: {result['text']!r}")
raise SystemExit(0 if passed else 1)
PY

stop_app

open -n "$APP" --args \
    --hid-probe-file "$FIXTURE" \
    --hid-use-standard-preferences \
    --result "$BASELINE_RESULT"

python3 - "$BASELINE_RESULT" <<'PY'
import json
import os
import sys
import time

path = sys.argv[1]
deadline = time.monotonic() + 15
while (not os.path.exists(path) or os.path.getsize(path) == 0) and time.monotonic() < deadline:
    time.sleep(0.1)
if not os.path.exists(path) or os.path.getsize(path) == 0:
    raise SystemExit("FAIL before-learning: no result")
with open(path, encoding="utf-8") as handle:
    result = json.load(handle)
passed = (
    result["postEventAccess"]
    and result["text"] == "qazwsxedc "
    and result.get("pasteboardChangeCountDelta") == 0
    and result.get("postedAutomaticReplacementCount") == 0
    and result.get("verifiedAutomaticReplacementCount") == 0
    and result.get("postedManualReplacementCount") == 0
    and result.get("verifiedManualReplacementCount") == 0
)
print(f"{'PASS' if passed else 'FAIL'} before-learning: {result['text']!r}")
raise SystemExit(0 if passed else 1)
PY

stop_app

open -n "$APP" --args \
    --hid-probe manual-learning-double-shift \
    --hid-use-standard-preferences \
    --result "$RESULT"

python3 - "$RESULT" <<'PY'
import json
import os
import sys
import time

path = sys.argv[1]
deadline = time.monotonic() + 15
while (not os.path.exists(path) or os.path.getsize(path) == 0) and time.monotonic() < deadline:
    time.sleep(0.1)
if not os.path.exists(path) or os.path.getsize(path) == 0:
    raise SystemExit("FAIL manual-learning-double-shift: no result")

with open(path, encoding="utf-8") as handle:
    result = json.load(handle)
expected_word = "йфяцычувс"
passed = (
    result["postEventAccess"]
    and result.get("manualText") == expected_word
    and result["text"] == expected_word + " "
    and result.get("learningConfirmed") is True
    and result.get("pasteboardChangeCountDelta") == 0
    and result.get("triggerPasteboardChangeCountDelta") == 0
    and result.get("manualOutcome") == "verified"
    and result.get("postedManualReplacementCount") == 0
    and result.get("verifiedManualReplacementCount") == 1
    and result.get("postedAutomaticReplacementCount") == 1
    and result.get("verifiedAutomaticReplacementCount") == 1
    and result.get("finalLayoutLanguage", "").lower().startswith("ru")
)
print(
    f"{'PASS' if passed else 'FAIL'} manual-learning-double-shift: "
    f"manual={result.get('manualText')!r} automatic={result['text']!r} "
    f"confirmed={result.get('learningConfirmed')!r}"
)
raise SystemExit(0 if passed else 1)
PY

stop_app

open -n "$APP" --args \
    --hid-probe manual-buffer-double-shift \
    --hid-use-standard-preferences \
    --result "$BUFFER_RESULT"

python3 - "$BUFFER_RESULT" <<'PY'
import json
import os
import sys
import time

path = sys.argv[1]
deadline = time.monotonic() + 15
while (not os.path.exists(path) or os.path.getsize(path) == 0) and time.monotonic() < deadline:
    time.sleep(0.1)
if not os.path.exists(path) or os.path.getsize(path) == 0:
    raise SystemExit("FAIL manual-buffer-double-shift: no result")
with open(path, encoding="utf-8") as handle:
    result = json.load(handle)
expected = "сейчас идет проверка"
passed = (
    result["postEventAccess"]
    and result["text"] == expected
    and result.get("manualText") == expected
    and result.get("pasteboardChangeCountDelta") == 0
    and result.get("triggerPasteboardChangeCountDelta") == 0
    and result.get("manualOutcome") == "verified"
    and result.get("postedManualReplacementCount") == 1
    and result.get("verifiedManualReplacementCount") == 1
    and result.get("postedAutomaticReplacementCount") == 0
    and result.get("verifiedAutomaticReplacementCount") == 0
    and result.get("finalLayoutLanguage", "").lower().startswith("ru")
    and not result.get("boundaryDeliveryTimeouts")
)
print(f"{'PASS' if passed else 'FAIL'} manual-buffer-double-shift: {result['text']!r}")
raise SystemExit(0 if passed else 1)
PY

stop_app

open -n "$APP" --args \
    --hid-probe-file "$FIXTURE" \
    --hid-use-standard-preferences \
    --result "$PERSISTED_RESULT"

python3 - "$PERSISTED_RESULT" <<'PY'
import json
import os
import sys
import time

path = sys.argv[1]
deadline = time.monotonic() + 15
while (not os.path.exists(path) or os.path.getsize(path) == 0) and time.monotonic() < deadline:
    time.sleep(0.1)
if not os.path.exists(path) or os.path.getsize(path) == 0:
    raise SystemExit("FAIL after-restart: no result")
with open(path, encoding="utf-8") as handle:
    result = json.load(handle)
passed = (
    result["postEventAccess"]
    and result["text"] == "йфяцычувс "
    and result.get("pasteboardChangeCountDelta") == 0
    and result.get("postedAutomaticReplacementCount") == 1
    and result.get("verifiedAutomaticReplacementCount") == 1
    and result.get("postedManualReplacementCount") == 0
    and result.get("verifiedManualReplacementCount") == 0
)
print(f"{'PASS' if passed else 'FAIL'} after-restart: {result['text']!r}")
raise SystemExit(0 if passed else 1)
PY
