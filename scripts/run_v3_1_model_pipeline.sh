#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="$ROOT/.build/v3.1-corpus"
EXAMPLES="$ROOT/.build/v3.1-examples"
MODEL_DIR="$ROOT/.build/v3.1-model"
MANIFEST="$ROOT/scripts/v3_1_training_sources.json"
PYTHON_BIN="${V3_1_PYTHON:-python3}"

mkdir -p "$EXAMPLES" "$MODEL_DIR"
python3 "$ROOT/scripts/prepare_v3_1_corpus.py"
swift build --package-path "$ROOT" -c release --product RuSwitcherModelTool
BIN_DIR="$(swift build --package-path "$ROOT" -c release --show-bin-path)"
TOOL="$BIN_DIR/RuSwitcherModelTool"
"$TOOL" schema --output "$MODEL_DIR/feature-schema.json"

"$TOOL" generate \
  --input "$CORPUS/train.jsonl" \
  --output "$EXAMPLES/train.jsonl" \
  --summary "$EXAMPLES/train-summary.json" \
  --split train \
  --pair-modulo 32

"$TOOL" generate \
  --input "$CORPUS/validation.jsonl" \
  --output "$EXAMPLES/validation.jsonl" \
  --summary "$EXAMPLES/validation-summary.json" \
  --split validation \
  --pair-modulo 8

MANIFEST_SHA="$(shasum -a 256 "$MANIFEST" | awk '{print $1}')"
OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 \
"$PYTHON_BIN" "$ROOT/scripts/train_v3_1_mlp.py" \
  --train "$EXAMPLES/train.jsonl" \
  --schema "$MODEL_DIR/feature-schema.json" \
  --output "$MODEL_DIR/layout-ranker-v1.json" \
  --report "$MODEL_DIR/optimizer-report.json" \
  --manifest-sha256 "$MANIFEST_SHA" \
  --model-version 2026.07-v3.1-ranker-9 \
  --hidden-size 8 \
  --epochs 10

"$TOOL" recalibrate \
  --validation "$EXAMPLES/validation.jsonl" \
  --model "$MODEL_DIR/layout-ranker-v1.json" \
  --output "$MODEL_DIR/layout-ranker-v1.json" \
  --report "$MODEL_DIR/validation-report.json" \
  --enforce-validation-gates

# The held-out test split is touched only after validation gates pass above.
"$TOOL" generate \
  --input "$CORPUS/test.jsonl" \
  --output "$EXAMPLES/test.jsonl" \
  --summary "$EXAMPLES/test-summary.json" \
  --split test \
  --pair-modulo 8

"$TOOL" evaluate \
  --examples "$EXAMPLES/test.jsonl" \
  --model "$MODEL_DIR/layout-ranker-v1.json" \
  --output "$MODEL_DIR/test-report.json" \
  --enforce-gates

if [[ "${PROMOTE:-0}" == "1" ]]; then
  cp "$MODEL_DIR/layout-ranker-v1.json" \
    "$ROOT/Sources/RuSwitcherCore/Resources/layout-ranker-v1.json"
fi
