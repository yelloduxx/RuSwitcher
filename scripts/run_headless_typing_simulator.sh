#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORT="$ROOT/.build/headless-typing-report.json"
NEGATIVE_REPORT="$ROOT/.build/headless-typing-negative-control.json"
BATCH_REPORT="$ROOT/.build/headless-typing-batch-report.json"
BATCH_RESULTS="$ROOT/.build/headless-typing-batch-results.jsonl"

cd "$ROOT"
swift run -c release RuSwitcherTypingSimulator \
  --input Tests/Fixtures/HID/mixed-layout-corpus-batch.json \
  --output "$REPORT" >/dev/null

if swift run -c release RuSwitcherTypingSimulator \
  --input Tests/Fixtures/Simulator/headless-event-negative-control.json \
  --output "$NEGATIVE_REPORT" >/dev/null; then
  echo "FAIL: headless simulator accepted the negative control"
  exit 1
fi

swift run -c release RuSwitcherTypingSimulator \
  --jobs 3 \
  --phrase-input Tests/Fixtures/Simulator/headless-event-batch.jsonl \
  --output "$BATCH_REPORT" \
  --results "$BATCH_RESULTS" >/dev/null

jq '{simulator, engine, passed, transactionCount, duplicateTransactionCount}' "$REPORT"
jq '{simulator, engine, passed, workers, fixtureTotal, fixturePassed, tokenTotal, actualTransactions, duplicateTransactionCount}' "$BATCH_REPORT"
echo "PASS: negative control was rejected"
