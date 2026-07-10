#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORT="$ROOT/.build/randomized-layout-v53-report.json"
TRACES="$ROOT/.build/randomized-layout-v53-phrases.jsonl"

cd "$ROOT"
swift run -c release RuSwitcherSimulator \
  --engine v4-shadow \
  --jobs 8 \
  --input Tests/Fixtures/Simulator/random-layout-v53-words.jsonl \
  --phrase-input Tests/Fixtures/Simulator/random-layout-v53-phrases.jsonl \
  --output "$REPORT" \
  --phrase-results "$TRACES" >/dev/null

jq '{total, passed, failed, phraseTotal, phrasePassed, v4LatencyP95, v4LatencyP99}' "$REPORT"
