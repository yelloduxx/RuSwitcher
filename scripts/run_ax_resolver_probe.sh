#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PID="${1:-}"

if [[ -z "$PID" ]]; then
  echo "Usage: $0 <process-id>" >&2
  echo "Probe warm (tree) then hot (cached/canonical) AX focused-editable resolution." >&2
  exit 64
fi

cd "$ROOT"
swift run -c release RuSwitcher --ax-resolver-probe "$PID"
