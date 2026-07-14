#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="${RUSWITCHER_ENGINE:-v3}"
ENGINE_TAG="${ENGINE//./-}"
REPORT="$ROOT/.build/randomized-layout-v53-$ENGINE_TAG-report.json"
TRACES="$ROOT/.build/randomized-layout-v53-$ENGINE_TAG-phrases.jsonl"

cd "$ROOT"
swift run -c release RuSwitcherSimulator \
  --engine "$ENGINE" \
  --jobs 8 \
  --input Tests/Fixtures/Simulator/random-layout-v53-words.jsonl \
  --phrase-input Tests/Fixtures/Simulator/random-layout-v53-phrases.jsonl \
  --output "$REPORT" \
  --phrase-results "$TRACES" >/dev/null

jq '{engine, total, passed, failed, phraseTotal, phrasePassed}' "$REPORT"
