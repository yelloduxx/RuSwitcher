import Foundation
import RuSwitcherCore

public struct PersonalizationAdapter: Codable, Equatable, Sendable {
    public private(set) var formatVersion: Int
    public private(set) var modelVersion: String
    public private(set) var weights: [Float]
    public private(set) var positiveCount: Int
    public private(set) var negativeCount: Int

    public init(modelVersion: String, embeddingSize: Int) {
        formatVersion = 1
        self.modelVersion = modelVersion
        weights = Array(repeating: 0, count: embeddingSize)
        positiveCount = 0
        negativeCount = 0
    }

    public mutating func migrate(modelVersion: String, embeddingSize: Int) {
        guard self.modelVersion != modelVersion || weights.count != embeddingSize else { return }
        self = PersonalizationAdapter(modelVersion: modelVersion, embeddingSize: embeddingSize)
    }

    public func score(_ featureDelta: [Float]) -> Float {
        zip(weights, featureDelta).reduce(0) { $0 + $1.0 * $1.1 }
    }

    public mutating func update(
        featureDelta: [Float],
        positive: Bool,
        strength: Float = 1,
        learningRate: Float,
        l2: Float
    ) {
        guard featureDelta.count == weights.count, !featureDelta.isEmpty else { return }
        let norm = sqrt(featureDelta.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { return }
        let normalized = featureDelta.map { $0 / max(1, norm) }
        let prediction = 1 / (1 + exp(-score(normalized)))
        let target: Float = positive ? 1 : 0
        let error = (prediction - target) * max(0, min(1, strength))
        for index in weights.indices {
            weights[index] -= learningRate * (error * normalized[index] + l2 * weights[index])
        }
        let weightNorm = sqrt(weights.reduce(0) { $0 + $1 * $1 })
        if weightNorm > 2 {
            let scale = 2 / weightNorm
            for index in weights.indices { weights[index] *= scale }
        }
        if positive { positiveCount += 1 } else { negativeCount += 1 }
    }
}
