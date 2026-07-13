#!/usr/bin/env python3
"""Train and export RuSwitcher V4's local byte-level candidate reranker.

The checked bootstrap model uses the pinned V3 frequency/phrase artifact and
synthetic keyboard-channel corruption. Release training can add pinned public
sentence corpora through --corpus-jsonl without changing the runtime format.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import random
import shutil
import struct
import subprocess
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from torch import nn
from torch.utils.data import DataLoader, Dataset


SEED = 20260710
MAX_BYTES = 192
MAX_CANDIDATES = 6
FEATURE_COUNT = 12
EMBEDDING_SIZE = 192
PAD, BOS, SEP, EOS = 0, 257, 258, 259
EN_TO_RU = dict(zip(
    "qwertyuiop[]asdfghjkl;'zxcvbnm,./`",
    "йцукенгшщзхъфывапролджэячсмитьбю.ё",
))
EN_TO_RU.update({key.upper(): value.upper() for key, value in list(EN_TO_RU.items())})
RU_TO_EN = {value: key for key, value in EN_TO_RU.items()}
RU_TO_EN.update({"ё": "`", "Ё": "~"})


def convert_layout(text: str) -> str:
    mapping = RU_TO_EN if any("а" <= ch.lower() <= "я" or ch.lower() == "ё" for ch in text) else EN_TO_RU
    return "".join(mapping.get(ch, ch) for ch in text)


def canonical(language: str) -> str:
    return language[:2].lower()


def parse_v3_model(path: Path) -> dict[str, object]:
    data = path.read_bytes()
    if data[:4] != b"RSLM":
        raise ValueError("invalid V3 model")
    section_count = struct.unpack_from("<H", data, 6)[0]
    directory_end = 20 + section_count * 12
    names = {
        2: "ru_words", 3: "en_words", 4: "ru_chars", 5: "en_chars",
        6: "ru_bigrams", 7: "en_bigrams", 8: "ru_trigrams", 9: "en_trigrams",
    }
    result: dict[str, object] = {}
    for index in range(section_count):
        kind, _, offset, length = struct.unpack_from("<HHII", data, 20 + index * 12)
        if kind in names:
            result[names[kind]] = json.loads(data[directory_end + offset:directory_end + offset + length])
    return result


def char_score(word: str, language: str, models: dict[str, object]) -> float:
    grams: dict[str, float] = models[f"{canonical(language)}_chars"]  # type: ignore[assignment]
    padded = "^" + word.lower() + "$"
    values = []
    for size in range(2, 6):
        for index in range(max(0, len(padded) - size + 1)):
            values.append(float(grams.get(padded[index:index + size], -16)))
    return sum(values) / len(values) if values else -16


def encode(context: str, candidate: str) -> list[int]:
    candidate_ids = [byte + 1 for byte in candidate.encode("utf-8")]
    available = max(0, MAX_BYTES - len(candidate_ids) - 3)
    context_ids = [byte + 1 for byte in context.encode("utf-8")][-available:]
    values = [BOS] + context_ids + [SEP] + candidate_ids + [EOS]
    return (values + [PAD] * MAX_BYTES)[:MAX_BYTES]


def language_label(text: str) -> int:
    letters = [ch.lower() for ch in text if ch.isalpha()]
    if letters and all("a" <= ch <= "z" for ch in letters):
        return 0
    if letters and all("а" <= ch <= "я" or ch == "ё" for ch in letters):
        return 1
    return 2


@dataclass
class Group:
    ids: np.ndarray
    features: np.ndarray
    label: int
    languages: np.ndarray
    both_known: bool
    clean: bool


def candidate_features(
    candidates: list[str], current: str, target: str, belief_delta: float,
    models: dict[str, object], kinds: list[int],
) -> np.ndarray:
    current_words: dict[str, float] = models[f"{current}_words"]  # type: ignore[assignment]
    target_words: dict[str, float] = models[f"{target}_words"]  # type: ignore[assignment]
    literal_core = candidates[0].strip(".,!?;:)]}>'\"").lower()
    literal_known = literal_core in current_words
    values = []
    for index, candidate in enumerate(candidates):
        core = candidate.strip(".,!?;:)]}>'\"").lower()
        target_known = core in target_words
        values.append([
            1.0 if index == 0 else 0.0,
            0.0 if index == 0 else 1.0,
            1.0 if kinds[index] == 2 else 0.0,
            1.0 if kinds[index] == 3 else 0.0,
            1.0 if current == "ru" else 0.0,
            1.0 if target == "ru" else 0.0,
            1.0 if literal_known else 0.0,
            1.0 if target_known else 0.0,
            max(-16, min(0, char_score(core, current, models))) / 16,
            max(-16, min(0, char_score(core, target, models))) / 16,
            belief_delta,
            1.0 if literal_known and target_known else 0.0,
        ])
    return np.asarray(values, dtype=np.float32)


def phrase_contexts(models: dict[str, object]) -> dict[tuple[str, str], list[str]]:
    result: dict[tuple[str, str], list[str]] = defaultdict(list)
    for language in ("en", "ru"):
        phrases: dict[str, float] = models[f"{language}_trigrams"]  # type: ignore[assignment]
        for phrase, _ in sorted(phrases.items(), key=lambda item: item[1], reverse=True):
            parts = phrase.split("\x1f")
            if len(parts) == 3 and len(result[(language, parts[-1])]) < 3:
                result[(language, parts[-1])].append(" ".join(parts[:-1]))
        bigrams: dict[str, float] = models[f"{language}_bigrams"]  # type: ignore[assignment]
        for phrase, _ in sorted(bigrams.items(), key=lambda item: item[1], reverse=True):
            parts = phrase.split("\x1f")
            if len(parts) == 2 and not result[(language, parts[-1])]:
                result[(language, parts[-1])].append(parts[0])
    return result


def make_group(
    context: str, candidates: list[str], label: int, current: str, target: str,
    belief_delta: float, models: dict[str, object], kinds: list[int], clean: bool,
) -> Group:
    ids = np.asarray([encode(context, candidate) for candidate in candidates], dtype=np.int32)
    features = candidate_features(candidates, current, target, belief_delta, models, kinds)
    current_words: dict[str, float] = models[f"{current}_words"]  # type: ignore[assignment]
    target_words: dict[str, float] = models[f"{target}_words"]  # type: ignore[assignment]
    both_known = candidates[0].lower() in current_words and candidates[1].lower() in target_words
    return Group(
        ids=ids,
        features=features,
        label=label,
        languages=np.asarray([language_label(candidate) for candidate in candidates], dtype=np.int64),
        both_known=both_known,
        clean=clean,
    )


def build_groups(models: dict[str, object], limit: int, corpus_paths: list[Path]) -> list[Group]:
    rng = random.Random(SEED)
    contexts = phrase_contexts(models)
    groups: list[Group] = []
    templates = {"en": ["this is", "we use", "put it", "click here"], "ru": ["это новый", "мы пишем", "сейчас это", "подними"]}
    punctuation = [",", ".", "!", "?"]

    for language, other in (("en", "ru"), ("ru", "en")):
        words: dict[str, float] = models[f"{language}_words"]  # type: ignore[assignment]
        ranked = [word for word, _ in sorted(words.items(), key=lambda item: item[1], reverse=True)[:limit]]
        for index, word in enumerate(ranked):
            mapped = convert_layout(word)
            if mapped == word:
                continue
            context_options = contexts.get((language, word)) or templates[language]
            context = context_options[index % len(context_options)]
            if index % 7 == 0:
                context = ("это " if language == "en" else "this ") + context
            groups.append(make_group(context, [word, mapped], 0, language, other, -0.8, models, [0, 1], True))
            groups.append(make_group(context, [mapped, word], 1, other, language, 0.8, models, [0, 1], False))
            if index % 9 == 0:
                mark = punctuation[index % len(punctuation)]
                intended = word + mark
                mistyped = convert_layout(intended)
                groups.append(make_group(context, [mistyped, intended], 1, other, language, 0.8, models, [0, 2], False))

    for path in corpus_paths:
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                value = json.loads(line)
                language = canonical(value["language"])
                words = str(value["text"]).split()
                if len(words) < 3 or language not in {"en", "ru"}:
                    continue
                word = words[-1].lower().strip(".,!?;:")
                mapped = convert_layout(word)
                other = "ru" if language == "en" else "en"
                context = " ".join(words[-5:-1])
                groups.append(make_group(context, [word, mapped], 0, language, other, -0.8, models, [0, 1], True))
                groups.append(make_group(context, [mapped, word], 1, other, language, 0.8, models, [0, 1], False))

    rng.shuffle(groups)
    return groups


class GroupDataset(Dataset):
    def __init__(self, groups: list[Group]):
        self.groups = groups

    def __len__(self) -> int:
        return len(self.groups)

    def __getitem__(self, index: int):
        group = self.groups[index]
        return (
            torch.from_numpy(group.ids), torch.from_numpy(group.features),
            torch.tensor(group.label), torch.from_numpy(group.languages),
        )


class TransformerBlock(nn.Module):
    def __init__(self):
        super().__init__()
        self.norm1 = nn.LayerNorm(EMBEDDING_SIZE)
        self.qkv = nn.Linear(EMBEDDING_SIZE, EMBEDDING_SIZE * 3)
        self.projection = nn.Linear(EMBEDDING_SIZE, EMBEDDING_SIZE)
        self.norm2 = nn.LayerNorm(EMBEDDING_SIZE)
        self.ff = nn.Sequential(
            nn.Linear(EMBEDDING_SIZE, 384), nn.GELU(), nn.Linear(384, EMBEDDING_SIZE)
        )

    def forward(self, value: torch.Tensor, mask: torch.Tensor) -> torch.Tensor:
        batch, length, _ = value.shape
        normalized = self.norm1(value)
        qkv = self.qkv(normalized).reshape(batch, length, 3, 6, 32).permute(2, 0, 3, 1, 4)
        query, key, content = qkv[0], qkv[1], qkv[2]
        attention = torch.matmul(query, key.transpose(-2, -1)) / math.sqrt(32)
        attention = attention.masked_fill(mask[:, None, None, :] == 0, -1e4)
        attended = torch.matmul(torch.softmax(attention, dim=-1), content)
        attended = attended.transpose(1, 2).reshape(batch, length, EMBEDDING_SIZE)
        value = value + self.projection(attended)
        return value + self.ff(self.norm2(value))


class LayoutReranker(nn.Module):
    def __init__(self):
        super().__init__()
        self.bytes = nn.Embedding(260, EMBEDDING_SIZE, padding_idx=PAD)
        self.positions = nn.Embedding(MAX_BYTES, EMBEDDING_SIZE)
        self.blocks = nn.ModuleList([TransformerBlock() for _ in range(6)])
        self.feature_projection = nn.Linear(FEATURE_COUNT, EMBEDDING_SIZE)
        self.embedding_norm = nn.LayerNorm(EMBEDDING_SIZE)
        self.rank_head = nn.Linear(EMBEDDING_SIZE, 1)
        self.language_head = nn.Linear(EMBEDDING_SIZE, 3)

    def forward(self, byte_ids: torch.Tensor, candidate_features: torch.Tensor):
        mask = (byte_ids != PAD).to(torch.float32)
        positions = torch.arange(MAX_BYTES, device=byte_ids.device).unsqueeze(0)
        value = self.bytes(byte_ids.to(torch.int64)) + self.positions(positions)
        for block in self.blocks:
            value = block(value, mask)
        pooled = (value * mask.unsqueeze(-1)).sum(1) / mask.sum(1, keepdim=True).clamp(min=1)
        embedding = self.embedding_norm(pooled + self.feature_projection(candidate_features))
        return self.rank_head(embedding).squeeze(-1), embedding, self.language_head(embedding)


def train(model: LayoutReranker, train_groups: list[Group], epochs: int) -> None:
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    model.to(device)
    loader = DataLoader(GroupDataset(train_groups), batch_size=16, shuffle=True, generator=torch.Generator().manual_seed(SEED))
    optimizer = torch.optim.AdamW(model.parameters(), lr=2e-4, weight_decay=1e-4)
    model.train()
    for epoch in range(epochs):
        total = 0.0
        for ids, features, labels, languages in loader:
            batch, candidates, length = ids.shape
            logits, _, language_logits = model(
                ids.reshape(batch * candidates, length).to(device),
                features.reshape(batch * candidates, FEATURE_COUNT).to(device),
            )
            grouped_logits = logits.reshape(batch, candidates)
            gold = nn.functional.cross_entropy(grouped_logits, labels.to(device))
            teacher = torch.full_like(grouped_logits, -2.5)
            teacher.scatter_(1, labels.to(device).unsqueeze(1), 2.5)
            distillation = nn.functional.kl_div(
                nn.functional.log_softmax(grouped_logits / 2, dim=-1),
                nn.functional.softmax(teacher / 2, dim=-1),
                reduction="batchmean",
            ) * 4
            language = nn.functional.cross_entropy(language_logits, languages.reshape(-1).to(device))
            loss = 0.7 * gold + 0.2 * distillation + 0.1 * language
            optimizer.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            total += float(loss.detach().cpu())
        print(f"epoch={epoch + 1} loss={total / max(1, len(loader)):.4f} device={device}")
    model.to("cpu").eval()


def calibrated_thresholds(model: LayoutReranker, groups: list[Group]) -> tuple[float, float, float, float, float]:
    logits = []
    labels = []
    both_known = []
    with torch.no_grad():
        for group in groups:
            score, _, _ = model(torch.from_numpy(group.ids), torch.from_numpy(group.features))
            logits.append(score.numpy())
            labels.append(group.label)
            both_known.append(group.both_known)
    values = np.asarray(logits)
    labels_array = np.asarray(labels)
    best_temperature = 1.0
    best_nll = float("inf")
    for temperature in np.linspace(0.5, 3.0, 26):
        shifted = values / temperature
        shifted -= shifted.max(axis=1, keepdims=True)
        probabilities = np.exp(shifted) / np.exp(shifted).sum(axis=1, keepdims=True)
        nll = -np.log(probabilities[np.arange(len(labels_array)), labels_array] + 1e-9).mean()
        if nll < best_nll:
            best_nll, best_temperature = float(nll), float(temperature)

    shifted = values / best_temperature
    shifted -= shifted.max(axis=1, keepdims=True)
    probabilities = np.exp(shifted) / np.exp(shifted).sum(axis=1, keepdims=True)
    ranked = np.sort(probabilities, axis=1)
    margins = ranked[:, -1] - ranked[:, -2]
    predicted = probabilities.argmax(axis=1)

    def choose(indices: np.ndarray, false_positive_limit: float) -> tuple[float, float]:
        for probability in np.arange(0.70, 1.0, 0.01):
            for margin in np.arange(0.10, 0.81, 0.05):
                selected = indices & (probabilities.max(axis=1) >= probability) & (margins >= margin)
                clean = selected & (labels_array == 0)
                false = clean & (predicted != labels_array)
                rate = false.sum() / max(1, clean.sum())
                if rate <= false_positive_limit:
                    return float(probability), float(margin)
        return 0.99, 0.8

    normal_probability, normal_margin = choose(np.ones(len(groups), dtype=bool), 0.001)
    known_probability, known_margin = choose(np.asarray(both_known), 0.0002)
    return best_temperature, normal_probability, normal_margin, known_probability, known_margin


class ExportWrapper(nn.Module):
    def __init__(self, model: LayoutReranker):
        super().__init__()
        self.model = model

    def forward(self, byte_ids: torch.Tensor, candidate_features: torch.Tensor):
        logits, embeddings, language_logits = self.model(byte_ids, candidate_features)
        return logits, embeddings, language_logits


def recursive_sha256(directory: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(value for value in directory.rglob("*") if value.is_file()):
        digest.update(path.relative_to(directory).as_posix().encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
    return digest.hexdigest()


def export_coreml(model: LayoutReranker, output_dir: Path, use_int8: bool) -> Path:
    package = output_dir / "LayoutRerankerV4.mlpackage"
    compiled_parent = output_dir / "compiled"
    shutil.rmtree(package, ignore_errors=True)
    shutil.rmtree(compiled_parent, ignore_errors=True)
    model.eval()
    traced = torch.jit.trace(
        ExportWrapper(model),
        (torch.zeros((MAX_CANDIDATES, MAX_BYTES), dtype=torch.int32),
         torch.zeros((MAX_CANDIDATES, FEATURE_COUNT), dtype=torch.float32)),
    )
    converted = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS13,
        inputs=[
            ct.TensorType(name="byte_ids", shape=(MAX_CANDIDATES, MAX_BYTES), dtype=np.int32),
            ct.TensorType(name="candidate_features", shape=(MAX_CANDIDATES, FEATURE_COUNT), dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="candidate_logits"),
            ct.TensorType(name="candidate_embeddings"),
            ct.TensorType(name="language_logits"),
        ],
        compute_precision=ct.precision.FLOAT16,
    )
    if use_int8:
        try:
            config = ct.optimize.coreml.OptimizationConfig(
                global_config=ct.optimize.coreml.OpLinearQuantizerConfig(
                    mode="linear_symmetric", dtype="int8", granularity="per_channel"
                )
            )
            converted = ct.optimize.coreml.linear_quantize_weights(converted, config=config)
        except Exception as error:
            print(f"warning: int8 weight compression unavailable, keeping fp16: {error}")
    converted.save(package)
    subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(compiled_parent)], check=True)
    return compiled_parent / "LayoutRerankerV4.mlmodelc"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, default=Path("Sources/RuSwitcherCore/Resources/language-model-v1.bin"))
    parser.add_argument("--corpus-jsonl", type=Path, action="append", default=[])
    parser.add_argument("--output-dir", type=Path, default=Path(".build/v4-model"))
    parser.add_argument(
        "--resource-dir",
        type=Path,
        default=Path("Experimental/V4/Sources/RuSwitcherExperimentalV4/Resources"),
    )
    parser.add_argument("--source-manifest", type=Path, default=Path("scripts/v4_training_sources.json"))
    parser.add_argument("--word-limit", type=int, default=5000)
    parser.add_argument("--epochs", type=int, default=2)
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--int8", action="store_true")
    args = parser.parse_args()

    random.seed(SEED)
    np.random.seed(SEED)
    torch.manual_seed(SEED)
    torch.use_deterministic_algorithms(False)
    models = parse_v3_model(args.model)
    groups = build_groups(models, args.word_limit, args.corpus_jsonl)
    train_groups = [group for index, group in enumerate(groups) if index % 10 != 0]
    validation_groups = [group for index, group in enumerate(groups) if index % 10 == 0]
    print(f"groups={len(groups)} train={len(train_groups)} validation={len(validation_groups)}")

    model = LayoutReranker()
    if args.checkpoint:
        model.load_state_dict(torch.load(args.checkpoint, map_location="cpu", weights_only=True))
        model.eval()
        print(f"loaded checkpoint={args.checkpoint}")
    else:
        train(model, train_groups, args.epochs)
    thresholds = calibrated_thresholds(model, validation_groups)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    compiled = export_coreml(model, args.output_dir, use_int8=args.int8)
    destination = args.resource_dir / "LayoutRerankerV4.mlmodelc"
    shutil.rmtree(destination, ignore_errors=True)
    shutil.copytree(compiled, destination)
    model_hash = recursive_sha256(destination)
    manifest = {
        "formatVersion": 1,
        "modelVersion": "2026.07-v4-bootstrap-2-" + ("int8" if args.int8 else "fp16"),
        "modelSHA256": model_hash,
        "maximumBytes": MAX_BYTES,
        "maximumCandidates": MAX_CANDIDATES,
        "featureCount": FEATURE_COUNT,
        "embeddingSize": EMBEDDING_SIZE,
        "temperature": thresholds[0],
        "minimumProbability": thresholds[1],
        "minimumMargin": thresholds[2],
        "bothKnownProbability": max(0.90, thresholds[3]),
        "bothKnownMargin": max(0.45, thresholds[4]),
        "learningRate": 0.02,
        "l2": 0.0001,
        "artifactClass": "bootstrap-shadow",
        "weightPrecision": "int8" if args.int8 else "fp16",
        "byteNormalization": "raw UTF-8 bytes shifted by one; NFC input",
        "trainingSeed": SEED,
        "trainingGroups": len(groups),
        "trainingSourceManifestSHA256": hashlib.sha256(args.source_manifest.read_bytes()).hexdigest(),
    }
    (args.resource_dir / "layout-model-v4.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    torch.save(model.state_dict(), args.output_dir / "layout-reranker-v4.pt")
    print(json.dumps({"manifest": manifest, "groups": len(groups)}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
