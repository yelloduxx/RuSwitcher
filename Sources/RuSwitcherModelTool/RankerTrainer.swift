import Foundation
import RuSwitcherCore

struct TrainOptions {
    let train: String
    let validation: String
    let output: String
    let report: String
    let manifestSHA256: String
    let modelVersion: String
    let epochs: Int
    let learningRate: Double
    let l2: Double
}

struct TrainingReport: Codable {
    let modelVersion: String
    let trainExamples: Int
    let validationExamples: Int
    let epochMeanLoss: [Double]
    let temperature: Double
    let thresholds: [String: Double]
    let validation: EvaluationReport
}

private struct ThresholdState {
    let falsePositives: Int
    let wrongReplacements: Int
    let truePositives: Int
    let punctuationTruePositives: Int
    let threshold: Double
}

private struct CalibrationBudget: Hashable {
    let falsePositives: Int
    let wrongReplacements: Int
}

private struct FamilyThresholdState {
    let truePositives: Int
    let punctuationTruePositives: Int
    let thresholds: [LayoutRankerRisk: Double]
}

final class RankerTrainer {
    private let decoder = JSONDecoder()

    func train(options: TrainOptions) throws -> TrainingReport {
        var weights = Array(repeating: 0.0, count: LayoutRankerFeatureSchema.names.count)
        var accumulatedSquares = Array(repeating: 1e-6, count: weights.count)
        var epochLosses: [Double] = []
        var trainExamples = 0

        for epoch in 0..<options.epochs {
            var reader = try JSONLineReader(path: options.train)
            var totalLoss = 0.0
            var count = 0
            while let line = try reader.next() {
                let example = try decoder.decode(StoredRankingExample.self, from: line)
                try validate(example)
                let featureRows = example.features.map { $0.map(Double.init) }
                let logits = featureRows.map { dot(weights, $0) }
                let probabilities = softmax(logits, temperature: 1)
                let expected = Set(example.expectedIndices)
                let expectedProbability = max(
                    expected.reduce(0) { $0 + probabilities[$1] },
                    .leastNonzeroMagnitude
                )
                totalLoss -= log(expectedProbability)
                var gradient = Array(repeating: 0.0, count: weights.count)
                for candidate in featureRows.indices {
                    let conditionalTarget = expected.contains(candidate)
                        ? probabilities[candidate] / expectedProbability
                        : 0
                    let coefficient = probabilities[candidate] - conditionalTarget
                    for feature in weights.indices {
                        gradient[feature] += coefficient * featureRows[candidate][feature]
                    }
                }
                let categoryWeight: Double
                if example.category == "protectedClean" {
                    categoryWeight = 2.0
                } else if example.category == "wrongPhysicalAmbiguous" {
                    categoryWeight = 4.0
                } else {
                    categoryWeight = 1.0
                }
                for feature in weights.indices {
                    let value = gradient[feature] * categoryWeight + options.l2 * weights[feature]
                    accumulatedSquares[feature] += value * value
                    weights[feature] -= options.learningRate * value / sqrt(accumulatedSquares[feature])
                }
                count += 1
            }
            try reader.close()
            if epoch == 0 { trainExamples = count }
            epochLosses.append(count == 0 ? 0 : totalLoss / Double(count))
        }

        let validationRecords = try loadCalibrationRecords(path: options.validation, weights: weights)
        let temperature = calibrateTemperature(records: validationRecords)
        let thresholds = calibrateThresholds(records: validationRecords, temperature: temperature)
        let artifact = LayoutRankerArtifact(
            modelVersion: options.modelVersion,
            featureSchemaVersion: LayoutRankerFeatureSchema.version,
            featureNames: LayoutRankerFeatureSchema.names,
            weights: weights,
            temperature: temperature,
            thresholds: thresholds,
            trainingManifestSHA256: options.manifestSHA256,
            trainExamples: trainExamples,
            validationExamples: validationRecords.count
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(artifact).write(to: URL(fileURLWithPath: options.output), options: .atomic)
        let validation = evaluateRecords(validationRecords, artifact: artifact)
        let report = TrainingReport(
            modelVersion: options.modelVersion,
            trainExamples: trainExamples,
            validationExamples: validationRecords.count,
            epochMeanLoss: epochLosses,
            temperature: artifact.temperature,
            thresholds: artifact.thresholds,
            validation: validation
        )
        try writeJSON(report, path: options.report)
        return report
    }

    func evaluate(examples path: String, artifact: LayoutRankerArtifact, output: String) throws -> EvaluationReport {
        let records = try loadCalibrationRecords(path: path, artifact: artifact)
        let report = evaluateRecords(records, artifact: artifact)
        try writeJSON(report, path: output)
        return report
    }

    func recalibrate(
        validation path: String,
        artifact: LayoutRankerArtifact,
        outputModel: String,
        outputReport: String
    ) throws -> EvaluationReport {
        let records = try loadCalibrationRecords(path: path, artifact: artifact)
        let temperature = calibrateTemperature(records: records)
        let thresholds = calibrateThresholds(records: records, temperature: temperature)
        let calibrated = LayoutRankerArtifact(
            formatVersion: artifact.formatVersion,
            modelVersion: artifact.modelVersion,
            featureSchemaVersion: artifact.featureSchemaVersion,
            featureNames: artifact.featureNames,
            weights: artifact.weights,
            hiddenWeights: artifact.hiddenWeights,
            hiddenBias: artifact.hiddenBias,
            outputWeights: artifact.outputWeights,
            temperature: temperature,
            thresholds: thresholds,
            trainingManifestSHA256: artifact.trainingManifestSHA256,
            trainExamples: artifact.trainExamples,
            validationExamples: records.count
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(calibrated).write(
            to: URL(fileURLWithPath: outputModel),
            options: .atomic
        )
        let report = evaluateRecords(records, artifact: calibrated)
        try writeJSON(report, path: outputReport)
        return report
    }

    private func loadCalibrationRecords(path: String, weights: [Double]) throws -> [CalibrationRecord] {
        var reader = try JSONLineReader(path: path)
        var result: [CalibrationRecord] = []
        while let line = try reader.next() {
            let example = try decoder.decode(StoredRankingExample.self, from: line)
            try validate(example)
            result.append(CalibrationRecord(
                logits: example.features.map { dot(weights, $0.map(Double.init)) },
                expectedIndices: Set(example.expectedIndices),
                expectedSwitch: example.expectedSwitch,
                risks: example.risks,
                category: example.category,
                baselineCorrect: example.baselineCorrect
            ))
        }
        try reader.close()
        return result
    }

    private func loadCalibrationRecords(
        path: String,
        artifact: LayoutRankerArtifact
    ) throws -> [CalibrationRecord] {
        var reader = try JSONLineReader(path: path)
        var result: [CalibrationRecord] = []
        while let line = try reader.next() {
            let example = try decoder.decode(StoredRankingExample.self, from: line)
            try validate(example)
            result.append(CalibrationRecord(
                logits: example.features.map { artifact.logit(features: $0.map(Double.init)) },
                expectedIndices: Set(example.expectedIndices),
                expectedSwitch: example.expectedSwitch,
                risks: example.risks,
                category: example.category,
                baselineCorrect: example.baselineCorrect
            ))
        }
        try reader.close()
        return result
    }

    private func calibrateTemperature(records: [CalibrationRecord]) -> Double {
        var bestTemperature = 1.0
        var bestLoss = Double.infinity
        for step in 5...80 {
            let temperature = Double(step) * 0.05
            let loss = negativeLogLikelihood(records: records, temperature: temperature)
            if loss < bestLoss {
                bestLoss = loss
                bestTemperature = temperature
            }
        }
        let lower = max(0.05, bestTemperature - 0.08)
        for step in 0...32 {
            let temperature = lower + Double(step) * 0.005
            let loss = negativeLogLikelihood(records: records, temperature: temperature)
            if loss < bestLoss {
                bestLoss = loss
                bestTemperature = temperature
            }
        }
        return bestTemperature
    }

    private func negativeLogLikelihood(records: [CalibrationRecord], temperature: Double) -> Double {
        guard !records.isEmpty else { return 0 }
        let total = records.reduce(0.0) { partial, record in
            let probabilities = softmax(record.logits, temperature: temperature)
            let expected = record.expectedIndices.reduce(0) { $0 + probabilities[$1] }
            return partial - log(max(expected, .leastNonzeroMagnitude))
        }
        return total / Double(records.count)
    }

    private func calibrateThresholds(
        records: [CalibrationRecord],
        temperature: Double
    ) -> [String: Double] {
        let predictions = records.map { record in
            (record, rawPrediction(logits: record.logits, risks: record.risks, temperature: temperature))
        }
        let family = LayoutRankerRisk.allCases.filter { $0 != .protected }
        let relevant = predictions.filter { $0.1.risk != LayoutRankerRisk.protected.rawValue }
        let falsePositiveBudget = maximumAllowedErrors(
            total: records.count(where: { !$0.expectedSwitch }),
            maximum: 0.001
        )
        let wrongReplacementBudget = maximumAllowedErrors(
            total: records.count(where: { $0.expectedSwitch }),
            maximum: 0.001
        )
        let selected = bestFamilyThresholds(
            family: family,
            records: relevant,
            falsePositiveBudget: falsePositiveBudget,
            wrongReplacementBudget: wrongReplacementBudget,
            strictRisks: [.bothKnown, .punctuationBothKnown, .punctuationAmbiguous]
        )
        var result = Dictionary(uniqueKeysWithValues: family.map {
            ($0.rawValue, selected[$0, default: 1])
        })
        result[LayoutRankerRisk.protected.rawValue] = 1
        return result
    }

    private func maximumAllowedErrors(total: Int, maximum: Double) -> Int {
        guard maximum > 0, total > 0 else { return 0 }
        let minimumForBound = Int(ceil(3.841_458_820_694_124 / maximum))
        guard total >= minimumForBound else { return 0 }
        var result = 0
        while result < total,
              wilsonUpper95(successes: result + 1, total: total) <= maximum {
            result += 1
        }
        return result
    }

    private func bestFamilyThresholds(
        family: [LayoutRankerRisk],
        records: [(CalibrationRecord, RawPrediction)],
        falsePositiveBudget: Int,
        wrongReplacementBudget: Int,
        strictRisks: Set<LayoutRankerRisk>
    ) -> [LayoutRankerRisk: Double] {
        var combined: [CalibrationBudget: FamilyThresholdState] = [
            CalibrationBudget(falsePositives: 0, wrongReplacements: 0):
                FamilyThresholdState(
                    truePositives: 0,
                    punctuationTruePositives: 0,
                    thresholds: [:]
                )
        ]
        for risk in family {
            let riskRecords = records.filter { $0.1.risk == risk.rawValue }
            let localFalsePositiveBudget = strictRisks.contains(risk) ? 0 : falsePositiveBudget
            let localWrongReplacementBudget = strictRisks.contains(risk) ? 0 : wrongReplacementBudget
            let states = thresholdStates(
                records: riskRecords,
                falsePositiveBudget: localFalsePositiveBudget,
                wrongReplacementBudget: localWrongReplacementBudget
            )
            var next: [CalibrationBudget: FamilyThresholdState] = [:]
            for (budget, current) in combined {
                for state in states {
                    let candidateBudget = CalibrationBudget(
                        falsePositives: budget.falsePositives + state.falsePositives,
                        wrongReplacements: budget.wrongReplacements + state.wrongReplacements
                    )
                    guard candidateBudget.falsePositives <= falsePositiveBudget,
                          candidateBudget.wrongReplacements <= wrongReplacementBudget else {
                        continue
                    }
                    var thresholds = current.thresholds
                    thresholds[risk] = state.threshold
                    let candidate = FamilyThresholdState(
                        truePositives: current.truePositives + state.truePositives,
                        punctuationTruePositives: current.punctuationTruePositives
                            + state.punctuationTruePositives,
                        thresholds: thresholds
                    )
                    if isBetter(candidate, than: next[candidateBudget]) {
                        next[candidateBudget] = candidate
                    }
                }
            }
            combined = next
        }
        return combined.sorted {
            if $0.value.punctuationTruePositives != $1.value.punctuationTruePositives {
                return $0.value.punctuationTruePositives > $1.value.punctuationTruePositives
            }
            if $0.value.truePositives != $1.value.truePositives {
                return $0.value.truePositives > $1.value.truePositives
            }
            let lhsErrors = $0.key.falsePositives + $0.key.wrongReplacements
            let rhsErrors = $1.key.falsePositives + $1.key.wrongReplacements
            return lhsErrors < rhsErrors
        }.first?.value.thresholds ?? [:]
    }

    private func thresholdStates(
        records: [(CalibrationRecord, RawPrediction)],
        falsePositiveBudget: Int,
        wrongReplacementBudget: Int
    ) -> [ThresholdState] {
        let grouped = Dictionary(grouping: records.filter { $0.1.winner != 0 }) {
            $0.1.margin
        }.sorted { $0.key > $1.key }
        var result: [CalibrationBudget: ThresholdState] = [
            CalibrationBudget(falsePositives: 0, wrongReplacements: 0): ThresholdState(
                falsePositives: 0,
                wrongReplacements: 0,
                truePositives: 0,
                punctuationTruePositives: 0,
                threshold: 1
            )
        ]
        var truePositives = 0
        var punctuationTruePositives = 0
        var falsePositives = 0
        var wrongReplacements = 0
        for (margin, entries) in grouped {
            for (record, prediction) in entries {
                if record.expectedSwitch {
                    if record.expectedIndices.contains(prediction.winner) {
                        truePositives += 1
                        if record.category.contains("Punctuation") {
                            punctuationTruePositives += 1
                        }
                    } else {
                        wrongReplacements += 1
                    }
                } else {
                    falsePositives += 1
                }
            }
            guard falsePositives <= falsePositiveBudget,
                  wrongReplacements <= wrongReplacementBudget else { break }
            let key = CalibrationBudget(
                falsePositives: falsePositives,
                wrongReplacements: wrongReplacements
            )
            result[key] = ThresholdState(
                falsePositives: falsePositives,
                wrongReplacements: wrongReplacements,
                truePositives: truePositives,
                punctuationTruePositives: punctuationTruePositives,
                threshold: max(0, margin - 1e-9)
            )
        }
        return Array(result.values)
    }

    private func isBetter(
        _ candidate: FamilyThresholdState,
        than existing: FamilyThresholdState?
    ) -> Bool {
        guard let existing else { return true }
        if candidate.punctuationTruePositives != existing.punctuationTruePositives {
            return candidate.punctuationTruePositives > existing.punctuationTruePositives
        }
        return candidate.truePositives > existing.truePositives
    }

    private func evaluateRecords(
        _ records: [CalibrationRecord],
        artifact: LayoutRankerArtifact
    ) -> EvaluationReport {
        var total = MetricBucket()
        var categories: [String: MetricBucket] = [:]
        var risks: [String: MetricBucket] = [:]
        var rawTopOne = MetricBucket()
        var rawCategories: [String: MetricBucket] = [:]
        var rawRisks: [String: MetricBucket] = [:]
        var baselineExpectedSwitchCorrect = 0
        for record in records {
            let prediction = rawPrediction(
                logits: record.logits,
                risks: record.risks,
                temperature: artifact.temperature
            )
            let threshold = artifact.thresholds[prediction.risk] ?? 1
            let switched = prediction.winner != 0
                && prediction.risk != LayoutRankerRisk.protected.rawValue
                && prediction.margin >= threshold
            let correct: Bool
            if record.expectedSwitch {
                correct = switched && record.expectedIndices.contains(prediction.winner)
            } else {
                correct = !switched
            }
            let rawSwitched = prediction.winner != 0
            let rawCorrect = record.expectedSwitch
                ? rawSwitched && record.expectedIndices.contains(prediction.winner)
                : !rawSwitched
            update(
                &rawTopOne,
                record: record,
                prediction: prediction,
                switched: rawSwitched,
                correct: rawCorrect
            )
            var rawCategory = rawCategories[record.category, default: MetricBucket()]
            update(
                &rawCategory,
                record: record,
                prediction: prediction,
                switched: rawSwitched,
                correct: rawCorrect
            )
            rawCategories[record.category] = rawCategory
            var rawRisk = rawRisks[prediction.risk, default: MetricBucket()]
            update(
                &rawRisk,
                record: record,
                prediction: prediction,
                switched: rawSwitched,
                correct: rawCorrect
            )
            rawRisks[prediction.risk] = rawRisk
            update(
                &total,
                record: record,
                prediction: prediction,
                switched: switched,
                correct: correct
            )
            var category = categories[record.category, default: MetricBucket()]
            update(&category, record: record, prediction: prediction, switched: switched, correct: correct)
            categories[record.category] = category
            var risk = risks[prediction.risk, default: MetricBucket()]
            update(&risk, record: record, prediction: prediction, switched: switched, correct: correct)
            risks[prediction.risk] = risk
            if record.expectedSwitch && record.baselineCorrect { baselineExpectedSwitchCorrect += 1 }
        }
        let cleanTotal = total.total - total.expectedSwitch
        let baselineAccuracy = total.total == 0 ? 1 : Double(total.baselineCorrect) / Double(total.total)
        // The 99% recall requirement applies only when the lattice has one
        // known punctuation path. Ambiguous, short and OOV paths are governed
        // by the false/wrong-replacement gates and may safely abstain.
        let punctuation = risks[LayoutRankerRisk.punctuation.rawValue] ?? MetricBucket()
        let baselineRecall = total.expectedSwitch == 0
            ? 1
            : Double(baselineExpectedSwitchCorrect) / Double(total.expectedSwitch)
        let protectedConversions = risks[LayoutRankerRisk.protected.rawValue]?.falsePositives ?? 0
        let upper = wilsonUpper95(successes: total.falsePositives, total: cleanTotal)
        let wrongUpper = wilsonUpper95(
            successes: total.wrongReplacements,
            total: total.expectedSwitch
        )
        let bothKnownWrong = (risks[LayoutRankerRisk.bothKnown.rawValue]?.wrongReplacements ?? 0)
            + (risks[LayoutRankerRisk.punctuationBothKnown.rawValue]?.wrongReplacements ?? 0)
            + (risks[LayoutRankerRisk.punctuationAmbiguous.rawValue]?.wrongReplacements ?? 0)
        let gates = [
            "cleanFalsePositiveUpper95": upper <= 0.001,
            "wrongReplacementUpper95": wrongUpper <= 0.001,
            "bothKnownWrongReplacements": bothKnownWrong == 0,
            "protectedNeverConverts": protectedConversions == 0,
            "wrongLayoutRecallNotBelowBaseline": total.recall + 1e-12 >= baselineRecall,
            "punctuationRecall": punctuation.recall >= 0.99,
            "accuracyNotBelowBaseline": total.accuracy + 1e-12 >= baselineAccuracy,
        ]
        return EvaluationReport(
            modelVersion: artifact.modelVersion,
            total: total,
            byCategory: categories,
            byRisk: risks,
            rawTopOne: rawTopOne,
            rawByCategory: rawCategories,
            rawByRisk: rawRisks,
            cleanFalsePositiveUpper95: upper,
            wrongReplacementUpper95: wrongUpper,
            baselineAccuracy: baselineAccuracy,
            modelAccuracy: total.accuracy,
            gates: gates
        )
    }

    private func update(
        _ bucket: inout MetricBucket,
        record: CalibrationRecord,
        prediction: RawPrediction,
        switched: Bool,
        correct: Bool
    ) {
        bucket.total += 1
        if correct { bucket.correct += 1 }
        if record.baselineCorrect { bucket.baselineCorrect += 1 }
        if record.expectedSwitch {
            bucket.expectedSwitch += 1
            if switched && record.expectedIndices.contains(prediction.winner) {
                bucket.switchedCorrectly += 1
            } else if switched {
                bucket.wrongReplacements += 1
            } else {
                bucket.safeMisses += 1
                if prediction.winner != 0 { bucket.abstained += 1 }
            }
        } else if switched {
            bucket.falsePositives += 1
        } else if prediction.winner != 0 {
            bucket.abstained += 1
        }
    }

    private func validate(_ example: StoredRankingExample) throws {
        guard !example.features.isEmpty,
              example.features.count == example.risks.count,
              example.features.allSatisfy({ $0.count == LayoutRankerFeatureSchema.names.count }),
              !example.expectedIndices.isEmpty,
              example.expectedIndices.allSatisfy({ example.features.indices.contains($0) }) else {
            throw NSError(domain: "RuSwitcherModelTool", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "invalid stored feature group \(example.id)"
            ])
        }
    }

    private func dot<T: BinaryFloatingPoint>(_ weights: [Double], _ features: [T]) -> Double {
        zip(weights, features).reduce(0) { $0 + $1.0 * Double($1.1) }
    }
}
