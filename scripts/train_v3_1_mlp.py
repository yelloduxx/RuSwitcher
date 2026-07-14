#!/usr/bin/env python3
"""Train RuSwitcher's compact candidate ranker from text-free feature rows."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
from pathlib import Path

import numpy as np


def batches(path: Path, batch_size: int, feature_count: int, maximum: int | None):
    batch: list[dict[str, object]] = []
    seen = 0
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            example = json.loads(line)
            features = example.get("features")
            expected = example.get("expectedIndices")
            if not isinstance(features, list) or not features:
                raise ValueError("feature group is empty")
            if any(not isinstance(row, list) or len(row) != feature_count for row in features):
                raise ValueError("feature row does not match schema")
            if not isinstance(expected, list) or not expected:
                raise ValueError("expected candidate set is empty")
            if any(not isinstance(index, int) or not 0 <= index < len(features) for index in expected):
                raise ValueError("expected candidate index is out of range")
            batch.append(example)
            seen += 1
            if len(batch) == batch_size:
                yield batch
                batch = []
            if maximum is not None and seen >= maximum:
                break
    if batch:
        yield batch


def arrays(examples: list[dict[str, object]], feature_count: int):
    candidate_count = max(len(example["features"]) for example in examples)
    x = np.zeros((len(examples), candidate_count, feature_count), dtype=np.float64)
    mask = np.zeros((len(examples), candidate_count), dtype=bool)
    expected = np.zeros((len(examples), candidate_count), dtype=bool)
    sample_weight = np.ones((len(examples), 1), dtype=np.float64)
    for row, example in enumerate(examples):
        values = np.asarray(example["features"], dtype=np.float64)
        x[row, : values.shape[0], :] = values
        mask[row, : values.shape[0]] = True
        expected[row, example["expectedIndices"]] = True
        if example.get("category") == "protectedClean":
            sample_weight[row, 0] = 2.0
    return x, mask, expected, sample_weight


def adam_step(parameter, gradient, first, second, step, learning_rate):
    beta1 = 0.9
    beta2 = 0.999
    first *= beta1
    first += (1 - beta1) * gradient
    second *= beta2
    second += (1 - beta2) * gradient * gradient
    corrected_first = first / (1 - beta1**step)
    corrected_second = second / (1 - beta2**step)
    parameter -= learning_rate * corrected_first / (np.sqrt(corrected_second) + 1e-8)


def atomic_json(value: object, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, sort_keys=True, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, destination)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def train(args: argparse.Namespace) -> dict[str, object]:
    schema = json.loads(args.schema.read_text(encoding="utf-8"))
    feature_names = schema["featureNames"]
    feature_count = len(feature_names)
    hidden_size = args.hidden_size
    rng = np.random.default_rng(args.seed)

    linear = np.zeros(feature_count, dtype=np.float64)
    hidden = rng.normal(0, np.sqrt(2 / (feature_count + hidden_size)), (hidden_size, feature_count))
    bias = np.zeros(hidden_size, dtype=np.float64)
    output = rng.normal(0, np.sqrt(1 / hidden_size), hidden_size)
    parameters = [linear, hidden, bias, output]
    first_moments = [np.zeros_like(value) for value in parameters]
    second_moments = [np.zeros_like(value) for value in parameters]
    losses: list[float] = []
    train_examples = 0
    step = 0

    for epoch in range(args.epochs):
        total_loss = 0.0
        total_weight = 0.0
        epoch_examples = 0
        for examples in batches(args.train, args.batch_size, feature_count, args.max_examples):
            x, mask, expected, sample_weight = arrays(examples, feature_count)
            hidden_values = np.tanh(np.einsum("bcf,hf->bch", x, hidden) + bias)
            logits = np.einsum("bcf,f->bc", x, linear) + np.einsum("bch,h->bc", hidden_values, output)
            logits = np.where(mask, logits, -1e30)
            logits -= np.max(logits, axis=1, keepdims=True)
            probabilities = np.exp(logits) * mask
            probabilities /= np.sum(probabilities, axis=1, keepdims=True)
            expected_probability = np.sum(probabilities * expected, axis=1, keepdims=True)
            expected_probability = np.maximum(expected_probability, np.finfo(np.float64).tiny)
            total_loss -= float(np.sum(np.log(expected_probability) * sample_weight))
            total_weight += float(np.sum(sample_weight))

            coefficient = probabilities.copy()
            coefficient -= probabilities * expected / expected_probability
            coefficient *= sample_weight / np.sum(sample_weight)
            gradient_linear = np.einsum("bc,bcf->f", coefficient, x)
            gradient_output = np.einsum("bc,bch->h", coefficient, hidden_values)
            dz = coefficient[:, :, None] * output * (1 - hidden_values * hidden_values)
            gradient_hidden = np.einsum("bch,bcf->hf", dz, x)
            gradient_bias = np.sum(dz, axis=(0, 1))
            gradients = [gradient_linear, gradient_hidden, gradient_bias, gradient_output]
            for parameter, gradient in zip(parameters, gradients):
                gradient += args.l2 * parameter
            norm = np.sqrt(sum(float(np.sum(gradient * gradient)) for gradient in gradients))
            if norm > args.gradient_clip:
                gradients = [gradient * (args.gradient_clip / norm) for gradient in gradients]
            step += 1
            for values in zip(parameters, gradients, first_moments, second_moments):
                adam_step(*values, step, args.learning_rate)
            epoch_examples += len(examples)
        if epoch == 0:
            train_examples = epoch_examples
        losses.append(total_loss / max(total_weight, 1))

    thresholds = {risk: 1.0 for risk in schema["risks"]}
    artifact = {
        "formatVersion": 2,
        "modelVersion": args.model_version,
        "featureSchemaVersion": schema["featureSchemaVersion"],
        "featureNames": feature_names,
        "weights": linear.tolist(),
        "hiddenWeights": hidden.tolist(),
        "hiddenBias": bias.tolist(),
        "outputWeights": output.tolist(),
        "temperature": 1.0,
        "thresholds": thresholds,
        "trainingManifestSHA256": args.manifest_sha256,
        "trainExamples": train_examples,
        "validationExamples": 0,
    }
    atomic_json(artifact, args.output)
    digest = hashlib.sha256(args.output.read_bytes()).hexdigest()
    report = {
        "formatVersion": 1,
        "modelVersion": args.model_version,
        "numpyVersion": np.__version__,
        "seed": args.seed,
        "hiddenSize": hidden_size,
        "epochs": args.epochs,
        "batchSize": args.batch_size,
        "learningRate": args.learning_rate,
        "l2": args.l2,
        "gradientClip": args.gradient_clip,
        "trainExamples": train_examples,
        "epochMeanLoss": losses,
        "artifactSHA256BeforeCalibration": digest,
    }
    atomic_json(report, args.report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--train", type=Path, required=True)
    parser.add_argument("--schema", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--manifest-sha256", required=True)
    parser.add_argument("--model-version", required=True)
    parser.add_argument("--hidden-size", type=int, default=8)
    parser.add_argument("--epochs", type=int, default=5)
    parser.add_argument("--batch-size", type=int, default=256)
    parser.add_argument("--learning-rate", type=float, default=0.003)
    parser.add_argument("--l2", type=float, default=1e-5)
    parser.add_argument("--gradient-clip", type=float, default=5.0)
    parser.add_argument("--seed", type=int, default=1729)
    parser.add_argument("--max-examples", type=int)
    args = parser.parse_args()
    if not 1 <= args.hidden_size <= 32 or args.epochs < 1 or args.batch_size < 1:
        parser.error("hidden size, epochs and batch size must be positive")
    print(json.dumps(train(args), sort_keys=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
