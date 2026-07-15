#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$ROOT/.build/hid-authored-alternating-phrases.json"
MANIFEST="$ROOT/.build/hid-authored-alternating-phrases.txt"

python3 "$ROOT/scripts/generate_hid_authored_fixture.py" \
    "$FIXTURE" --manifest "$MANIFEST"

RUSWITCH_APP="${RUSWITCH_APP:-/Applications/RuSwitcherAX.app}" \
    bash "$ROOT/scripts/run_hid_batch_tests.sh" "$FIXTURE"
