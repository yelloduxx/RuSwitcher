#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORT="${TMPDIR:-/tmp}/ruswitcher-negative-control.json"

cd "$ROOT"
if swift run -c release RuSwitcherSimulator \
    --phrase-input Tests/Fixtures/Simulator/intentional-phrase-failure.jsonl \
    --limit 1 \
    --output "$REPORT" >/dev/null; then
    echo "FAIL: simulator accepted an intentionally wrong expectation"
    exit 1
fi

if ! grep -q 'intentional-negative-control' "$REPORT"; then
    echo "FAIL: simulator failed, but did not report the negative control"
    exit 1
fi

echo "PASS: simulator rejected the intentionally wrong phrase"
