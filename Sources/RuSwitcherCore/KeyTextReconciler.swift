import Foundation

public struct ReconciledKeyText: Equatable, Sendable {
    public let original: String
    public let converted: String
    public let sourceWasOpposite: Bool

    public init(original: String, converted: String, sourceWasOpposite: Bool) {
        self.original = original
        self.converted = converted
        self.sourceWasOpposite = sourceWasOpposite
    }
}

public enum KeyTextReconciler {
    /// TIS can lag behind the text input context briefly after a layout switch.
    /// The Unicode payload actually delivered by the event is authoritative when
    /// it exactly matches one of the two physical-key reconstructions.
    public static func reconcile(
        reconstructedOriginal: String,
        reconstructedConverted: String,
        producedText: String?
    ) -> ReconciledKeyText {
        let original = reconstructedOriginal.precomposedStringWithCanonicalMapping
        let converted = reconstructedConverted.precomposedStringWithCanonicalMapping
        guard let produced = producedText?.precomposedStringWithCanonicalMapping else {
            return ReconciledKeyText(original: original, converted: converted, sourceWasOpposite: false)
        }
        if produced == converted, produced != original {
            return ReconciledKeyText(original: converted, converted: original, sourceWasOpposite: true)
        }
        return ReconciledKeyText(original: original, converted: converted, sourceWasOpposite: false)
    }
}
