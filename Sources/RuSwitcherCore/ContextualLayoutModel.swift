import CoreML
import CryptoKit
import Foundation

public final class ContextualLayoutModel: @unchecked Sendable, ContextualLayoutScoring {
    public static let bundled: ContextualLayoutModel? = try? ContextualLayoutModel()

    public let manifest: ContextualModelManifest
    private let model: MLModel

    public init(modelURL: URL? = nil, manifestURL: URL? = nil) throws {
        let resolvedManifestURL = manifestURL
            ?? Bundle.main.url(forResource: "layout-model-v4", withExtension: "json")
            ?? Bundle.module.url(forResource: "layout-model-v4", withExtension: "json")
        let resolvedModelURL = modelURL
            ?? Bundle.main.url(forResource: "LayoutRerankerV4", withExtension: "mlmodelc")
            ?? Bundle.module.url(forResource: "LayoutRerankerV4", withExtension: "mlmodelc")
        guard let resolvedManifestURL, let resolvedModelURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        manifest = try JSONDecoder().decode(
            ContextualModelManifest.self,
            from: Data(contentsOf: resolvedManifestURL)
        )
        guard try Self.recursiveSHA256(of: resolvedModelURL) == manifest.modelSHA256 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: resolvedModelURL, configuration: configuration)
        _ = try? score(
            byteIDs: Array(repeating: Array(repeating: 0, count: manifest.maximumBytes), count: manifest.maximumCandidates),
            features: Array(repeating: Array(repeating: 0, count: manifest.featureCount), count: manifest.maximumCandidates)
        )
    }

    public func score(byteIDs: [[Int32]], features: [[Float]]) throws -> ContextualModelOutput {
        let candidates = manifest.maximumCandidates
        let bytes = manifest.maximumBytes
        let featureCount = manifest.featureCount
        let ids = try MLMultiArray(shape: [NSNumber(value: candidates), NSNumber(value: bytes)], dataType: .int32)
        let featureArray = try MLMultiArray(
            shape: [NSNumber(value: candidates), NSNumber(value: featureCount)],
            dataType: .float32
        )
        let idPointer = ids.dataPointer.bindMemory(to: Int32.self, capacity: candidates * bytes)
        let featurePointer = featureArray.dataPointer.bindMemory(to: Float.self, capacity: candidates * featureCount)
        for candidate in 0..<candidates {
            for index in 0..<bytes {
                idPointer[candidate * bytes + index] = byteIDs[safe: candidate]?[safe: index] ?? 0
            }
            for index in 0..<featureCount {
                featurePointer[candidate * featureCount + index] = features[safe: candidate]?[safe: index] ?? 0
            }
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "byte_ids": MLFeatureValue(multiArray: ids),
            "candidate_features": MLFeatureValue(multiArray: featureArray),
        ])
        let started = ContinuousClock.now
        let prediction = try model.prediction(from: provider)
        let duration = started.duration(to: .now)
        let latency = Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1e15
        guard let logitsArray = prediction.featureValue(for: "candidate_logits")?.multiArrayValue,
              let embeddingsArray = prediction.featureValue(for: "candidate_embeddings")?.multiArrayValue else {
            throw CocoaError(.coderInvalidValue)
        }
        let logits = (0..<candidates).map { Self.floatValue(in: logitsArray, at: $0) }
        let embeddings = (0..<candidates).map { candidate in
            (0..<manifest.embeddingSize).map {
                Self.floatValue(
                    in: embeddingsArray,
                    at: candidate * manifest.embeddingSize + $0
                )
            }
        }
        return ContextualModelOutput(logits: logits, embeddings: embeddings, latencyMilliseconds: latency)
    }

    private static func floatValue(in array: MLMultiArray, at index: Int) -> Float {
        switch array.dataType {
        case .float16:
            let pointer = array.dataPointer.bindMemory(to: UInt16.self, capacity: array.count)
            return floatFromIEEE754Half(pointer[index])
        case .float32:
            return array.dataPointer.bindMemory(to: Float.self, capacity: array.count)[index]
        case .double:
            return Float(array.dataPointer.bindMemory(to: Double.self, capacity: array.count)[index])
        default:
            return array[index].floatValue
        }
    }

    private static func floatFromIEEE754Half(_ half: UInt16) -> Float {
        let sign = UInt32(half & 0x8000) << 16
        var exponent = Int((half >> 10) & 0x1f)
        var mantissa = UInt32(half & 0x03ff)
        let bits: UInt32
        if exponent == 0 {
            if mantissa == 0 {
                bits = sign
            } else {
                exponent = -14
                while (mantissa & 0x0400) == 0 {
                    mantissa <<= 1
                    exponent -= 1
                }
                mantissa &= 0x03ff
                bits = sign | UInt32(exponent + 127) << 23 | mantissa << 13
            }
        } else if exponent == 0x1f {
            bits = sign | 0x7f80_0000 | mantissa << 13
        } else {
            bits = sign | UInt32(exponent + 112) << 23 | mantissa << 13
        }
        return Float(bitPattern: bits)
    }

    private static func recursiveSHA256(of directory: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { throw CocoaError(.fileReadUnknown) }
        let files = enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted {
            $0.path.replacingOccurrences(of: directory.path + "/", with: "")
                < $1.path.replacingOccurrences(of: directory.path + "/", with: "")
        }
        var hasher = SHA256()
        for file in files {
            let relative = file.path.replacingOccurrences(of: directory.path + "/", with: "")
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: file, options: .mappedIfSafe))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
