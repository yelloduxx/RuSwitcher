#!/bin/bash
set -euo pipefail

APP="${RUSWITCH_APP:-/Applications/RuSwitcher.app}"
BIN="$APP/Contents/MacOS/RuSwitcher"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_FIXTURE="$ROOT/Tests/Fixtures/HID/mixed-layout-corpus-batch.json"

test -x "$BIN"
ACTUAL_APP_SHA256="$(shasum -a 256 "$BIN" | awk '{print $1}')"
EXPECTED_APP_SHA256="${RUSWITCH_APP_SHA256:-$ACTUAL_APP_SHA256}"
if [ "$ACTUAL_APP_SHA256" != "$EXPECTED_APP_SHA256" ]; then
    echo "FAIL: candidate SHA-256 mismatch"
    exit 1
fi
echo "Testing $BIN (sha256=$ACTUAL_APP_SHA256)"
if [ "$#" -eq 0 ]; then
    set -- "$DEFAULT_FIXTURE"
fi

failed=0
if [ -n "${HID_RESULT_PATH:-}" ] && [ "$#" -ne 1 ]; then
    echo "HID_RESULT_PATH requires exactly one fixture"
    exit 64
fi
for fixture in "$@"; do
    fixture="$(cd "$(dirname "$fixture")" && pwd)/$(basename "$fixture")"
    while read -r pid; do
        test -z "$pid" || kill "$pid" 2>/dev/null || true
    done < <(pgrep -f "$BIN" || true)
    for _ in {1..50}; do
        pgrep -f "$BIN" >/dev/null || break
        sleep 0.1
    done
    sleep "${HID_RESTART_SETTLE_SECONDS:-5}"

    fixture_name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["name"])' "$fixture")"
    typed_length="$(python3 -c 'import json,sys; print(sum(len(x["text"]) for x in json.load(open(sys.argv[1], encoding="utf-8"))["phases"]))' "$fixture")"
    result="${HID_RESULT_PATH:-$ROOT/.build/ruswitch-hid-batch-$$-$fixture_name.json}"
    rm -f "$result"

    probe_pattern="$BIN --hid-probe-file $fixture"
    launched=0
    for _ in {1..5}; do
        open "$APP" --args --hid-probe-file "$fixture" --result "$result"
        sleep 1
        if pgrep -f "$probe_pattern" >/dev/null; then
            launched=1
            break
        fi
    done
    if [ "$launched" -ne 1 ]; then
        echo "FAIL $fixture_name: LaunchServices returned no probe PID"
        failed=1
        continue
    fi
    timeout_ticks=$(( typed_length / 4 + 600 ))
    for ((tick=0; tick<timeout_ticks; tick++)); do
        test -f "$result" && break
        sleep 0.1
    done

    if ! test -f "$result"; then
        echo "FAIL $fixture_name: no result after $typed_length input characters"
        failed=1
        continue
    fi

    if python3 - "$fixture" "$result" <<'PY'
import json
import sys

fixture_path, result_path = sys.argv[1:]
with open(fixture_path, encoding="utf-8") as handle:
    fixture = json.load(handle)
with open(result_path, encoding="utf-8") as handle:
    result = json.load(handle)

expected = fixture["expectedText"]
actual = result["text"]
typed_length = sum(len(phase["text"]) for phase in fixture["phases"])
okay = (
    result["postEventAccess"]
    and actual == expected
    and result.get("pasteboardChangeCountDelta") == 0
    and result.get("unexpectedInputEventCount", 0) == 0
    and not result.get("boundaryDeliveryTimeouts", [])
    and (
        fixture.get("expectedTransactions") is None
        or (
            result.get("postedAutomaticReplacementCount") == fixture["expectedTransactions"]
            and result.get("verifiedAutomaticReplacementCount") == fixture["expectedTransactions"]
        )
    )
)
print(
    f"{'PASS' if okay else 'FAIL'} {fixture['name']}: "
    f"{len(fixture['phases'])} phases, {typed_length} input chars, "
    f"sources={','.join(fixture.get('sourceIDs', []))}"
)
if okay:
    if len(actual) <= 1_000:
        print(actual)
    else:
        print(f"exact text matched ({len(actual)} characters)")
        print(f"first 240: {actual[:240]!r}")
        print(f"last 240:  {actual[-240:]!r}")
else:
    mismatch = next(
        (index for index, pair in enumerate(zip(actual, expected)) if pair[0] != pair[1]),
        min(len(actual), len(expected)),
    )
    print(f"first mismatch at character {mismatch}")
    print(f"layout mismatch strokes: {result.get('layoutMismatchStrokes', [])}")
    print(f"unexpected input events: {result.get('unexpectedInputEventCount', 0)}")
    print(f"pasteboard change count delta: {result.get('pasteboardChangeCountDelta')}")
    print(f"boundary delivery timeouts: {result.get('boundaryDeliveryTimeouts', [])}")
    print(f"expected transactions: {fixture.get('expectedTransactions')}")
    print(f"posted transactions: {result.get('postedAutomaticReplacementCount')}")
    print(f"verified transactions: {result.get('verifiedAutomaticReplacementCount')}")
    print(f"expected: {expected!r}")
    print(f"actual:   {actual!r}")
raise SystemExit(0 if okay else 1)
PY
    then
        if [ "${KEEP_HID_RESULTS:-0}" = "1" ]; then
            echo "diagnostic result retained: $result"
        else
            rm -f "$result"
        fi
    else
        failed=1
        echo "diagnostic result retained: $result"
    fi
done

exit "$failed"
