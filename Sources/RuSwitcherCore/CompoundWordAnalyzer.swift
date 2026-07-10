import Foundation

public struct CompoundAnalysis: Equatable, Sendable {
    public let segments: [String]
    public let score: Double

    public init(segments: [String], score: Double) {
        self.segments = segments
        self.score = score
    }
}

public enum CompoundWordAnalyzer {
    private struct State {
        let segments: [String]
        let score: Double
    }

    public static func analyze(
        _ word: String,
        language: String,
        model: LanguageModelStore,
        maximumSegments: Int = 4
    ) -> CompoundAnalysis? {
        let normalized = FrequentWordLexicon.normalize(word)
        let characters = Array(normalized)
        guard characters.count >= 6, characters.count <= 40 else { return nil }

        var best: [Int: State] = [0: State(segments: [], score: 0)]
        for start in 0..<characters.count {
            guard let state = best[start], state.segments.count < maximumSegments else { continue }
            guard start + 3 <= characters.count else { continue }
            for end in (start + 3)...characters.count {
                let segment = String(characters[start..<end])
                let isProductivePrefix = start == 0
                    && model.productiveRussianParts.contains(segment)
                    && end < characters.count
                let isProductiveSuffix = end == characters.count
                    && start >= 4
                    && model.productiveRussianSuffixes.contains(segment)
                    && model.contains(String(characters[0..<start]), language: language)
                guard let wordScore = model.wordLogProbability(segment, language: language) else {
                    if !isProductivePrefix && !isProductiveSuffix { continue }
                    let morphologyBonus = isProductiveSuffix ? 2.4 : 1.2
                    let score = state.score + morphologyBonus + Double(segment.count) * 0.08
                    Self.store(State(segments: state.segments + [segment], score: score), at: end, in: &best)
                    continue
                }
                let normalizedFrequency = max(0.2, 7.5 + wordScore * 0.55)
                let splitPenalty = state.segments.isEmpty ? 0 : 1.8
                let score = state.score + normalizedFrequency + Double(segment.count) * 0.08 - splitPenalty
                Self.store(State(segments: state.segments + [segment], score: score), at: end, in: &best)
            }
        }

        guard let result = best[characters.count], result.segments.count >= 2 else { return nil }
        return CompoundAnalysis(segments: result.segments, score: result.score)
    }

    private static func store(_ candidate: State, at index: Int, in states: inout [Int: State]) {
        if candidate.score > (states[index]?.score ?? -.infinity) {
            states[index] = candidate
        }
    }
}
