#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESCRIPTION="$ROOT/.build/v3-only-package-description.json"
REPORT="$ROOT/.build/v3-only-simulator-report.json"
APP="${1:-$ROOT/RuSwitcher.app}"

cd "$ROOT"
mkdir -p "$ROOT/.build"
swift package describe --type json > "$DESCRIPTION"

python3 - "$DESCRIPTION" <<'PY'
import json
import sys

package = json.load(open(sys.argv[1], encoding="utf-8"))
targets = {target["name"]: target for target in package["targets"]}
for forbidden in ("RuSwitcherExperimentalV4", "SmartAutoConvertEngine"):
    if forbidden in targets:
        raise SystemExit(f"forbidden root target: {forbidden}")

app_dependencies = set(targets["RuSwitcher"]["target_dependencies"])
if app_dependencies != {"RuSwitcherCore", "RuSwitcherAppSupport"}:
    raise SystemExit(f"unexpected RuSwitcher dependencies: {sorted(app_dependencies)}")
if set(targets["RuSwitcherSimulator"]["target_dependencies"]) != {"RuSwitcherCore"}:
    raise SystemExit("corpus simulator is not V3-only")
if set(targets["RuSwitcherTypingSimulator"]["target_dependencies"]) != {"RuSwitcherCore"}:
    raise SystemExit("typing simulator is not V3-only")
PY

for removed in \
    Sources/RuSwitcherCore/SmartAutoConvertEngine.swift \
    Sources/RuSwitcherCore/TypingLanguageState.swift \
    Sources/RuSwitcherCore/LocalLanguageModel.swift \
    Sources/RuSwitcherCore/LayoutDetector.swift; do
    if [ -e "$ROOT/$removed" ]; then
        echo "FAIL: removed V2 source still exists: $removed"
        exit 1
    fi
done

if rg -q 'SmartAutoConvertEngine|ContextualLayoutDecoder|ContextualLayoutModel|RuSwitcherExperimentalV4|LayoutDetector|V3LayoutEngine|LayoutRanker' \
    "$ROOT/Sources/RuSwitcher"; then
    echo "FAIL: production executable still references an alternate decoder"
    exit 1
fi

swift run -c release RuSwitcherSimulator --jobs 4 --limit 100 --output "$REPORT" >/dev/null
jq -e '.engine == "v3" and .failed == 0' "$REPORT" >/dev/null

if [ -d "$APP" ]; then
    BINARY="$APP/Contents/MacOS/RuSwitcher"
    test -f "$APP/Contents/Resources/language-model-v1.bin"
    if [ -e "$APP/Contents/Resources/layout-ranker-v1.json" ]; then
        echo "FAIL: experimental V3.1 ranker found in application bundle"
        exit 1
    fi
    if find "$APP/Contents" \( -iname '*v4*' -o -iname '*LayoutReranker*' \) -print -quit | grep -q .; then
        echo "FAIL: V4 artifact found in application bundle"
        exit 1
    fi
    if otool -L "$BINARY" | rg -q 'CoreML'; then
        echo "FAIL: production executable links CoreML"
        exit 1
    fi
    if nm -j "$BINARY" 2>/dev/null | rg -q 'SmartAutoConvertEngine|ContextualLayoutDecoder|ContextualLayoutModel'; then
        echo "FAIL: alternate decoder symbol found in application executable"
        exit 1
    fi
fi

echo "PASS: production package, simulator and app bundle are V3-only"
