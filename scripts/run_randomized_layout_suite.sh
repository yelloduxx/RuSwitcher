#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORT="$ROOT/.build/randomized-layout-v53-report.json"
TRACES="$ROOT/.build/randomized-layout-v53-phrases.jsonl"

cd "$ROOT"
swift run -c release RuSwitcherSimulator \
  --jobs 8 \
  --input Tests/Fixtures/Simulator/random-layout-v53-words.jsonl \
  --phrase-input Tests/Fixtures/Simulator/random-layout-v53-phrases.jsonl \
  --output "$REPORT" \
  --phrase-results "$TRACES" >/dev/null

jq '{engine, total, passed, failed, phraseTotal, phrasePassed}' "$REPORT"
