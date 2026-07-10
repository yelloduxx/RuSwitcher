#!/bin/bash
set -euo pipefail

APP="/Applications/RuSwitcher.app"
DOMAIN="com.ruswitcher.app"
BACKUP="$(mktemp "${TMPDIR:-/tmp}/ruswitch-prefs.XXXXXX.plist")"
RESULT="$(mktemp "${TMPDIR:-/tmp}/ruswitch-learning.XXXXXX.json")"
BASELINE_RESULT="$(mktemp "${TMPDIR:-/tmp}/ruswitch-learning-baseline.XXXXXX.json")"
PERSISTED_RESULT="$(mktemp "${TMPDIR:-/tmp}/ruswitch-learning-persisted.XXXXXX.json")"
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

restore_preferences() {
    pkill -x RuSwitcher 2>/dev/null || true
    defaults import "$DOMAIN" "$BACKUP" >/dev/null
    rm -f "$BACKUP" "$RESULT" "$BASELINE_RESULT" "$PERSISTED_RESULT" "$FIXTURE"
    restart_app || true
}
trap restore_preferences EXIT

defaults write "$DOMAIN" com.ruswitcher.autoSwitch -bool true
defaults write "$DOMAIN" com.ruswitcher.autoConvert -bool true
defaults write "$DOMAIN" com.ruswitcher.triggerKey -string shift
defaults write "$DOMAIN" com.ruswitcher.triggerDoubleTap -bool true
defaults write "$DOMAIN" com.ruswitcher.smartEngineV4Mode -string shadow
defaults delete "$DOMAIN" com.ruswitcher.adaptiveRules.v1 2>/dev/null || true

printf '%s\n' \
    '{"name":"manual-learning-rule-check","phases":[{"sourceLanguage":"en","text":"qazwsxedc "}]}' \
    >"$FIXTURE"

restart_app
sleep 1

open -n "$APP" --args \
    --hid-probe-file "$FIXTURE" \
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
passed = result["postEventAccess"] and result["text"] == "qazwsxedc "
print(f"{'PASS' if passed else 'FAIL'} before-learning: {result['text']!r}")
raise SystemExit(0 if passed else 1)
PY

open -n "$APP" --args \
    --hid-probe manual-learning-double-shift \
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
)
print(
    f"{'PASS' if passed else 'FAIL'} manual-learning-double-shift: "
    f"manual={result.get('manualText')!r} automatic={result['text']!r} "
    f"confirmed={result.get('learningConfirmed')!r}"
)
raise SystemExit(0 if passed else 1)
PY

restart_app
sleep 1

open -n "$APP" --args \
    --hid-probe-file "$FIXTURE" \
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
passed = result["postEventAccess"] and result["text"] == "йфяцычувс "
print(f"{'PASS' if passed else 'FAIL'} after-restart: {result['text']!r}")
raise SystemExit(0 if passed else 1)
PY
