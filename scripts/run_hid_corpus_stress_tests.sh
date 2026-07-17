#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COUNT="${RUSWITCH_HID_PHRASES:-30}"
SEED="${RUSWITCH_HID_SEED:-7701}"
CORPUS="${1:-/Users/bezh/Downloads/mixed_word_layout_stress_test_pairs_5000.tsv}"
FIXTURE="$ROOT/.build/hid-random-phrases-${COUNT}-seed-${SEED}.json"
MANIFEST="$ROOT/.build/hid-random-phrases-${COUNT}-seed-${SEED}.txt"

python3 "$ROOT/scripts/generate_hid_phrase_fixture.py" \
    "$CORPUS" "$FIXTURE" --count "$COUNT" --seed "$SEED" --manifest "$MANIFEST"

RUSWITCH_APP="${RUSWITCH_APP:-/Applications/RuSwitcherAX.app}" \
    bash "$ROOT/scripts/run_hid_batch_tests.sh" "$FIXTURE"
