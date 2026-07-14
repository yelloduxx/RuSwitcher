import Foundation

public struct ReconciledKeyText: Equatable, Sendable {
    public let original: String
    public let converted: String
    public let sourceWasOpposite: Bool
    public let strokes: [PhysicalKeyStroke]?

    public init(
        original: String,
        converted: String,
        sourceWasOpposite: Bool,
        strokes: [PhysicalKeyStroke]? = nil
    ) {
        self.original = original
        self.converted = converted
        self.sourceWasOpposite = sourceWasOpposite
        self.strokes = strokes
    }
}

public enum KeyTextReconciler {
    /// TIS can lag behind the text input context briefly after a layout switch.
    /// The Unicode payload actually delivered by the event is authoritative when
    /// it exactly matches one of the two physical-key reconstructions.
    public static func reconcile(
        reconstructedOriginal: String,
        reconstructedConverted: String,
        producedText: String?,
        strokes: [PhysicalKeyStroke]? = nil
    ) -> ReconciledKeyText {
        let original = reconstructedOriginal.precomposedStringWithCanonicalMapping
        let converted = reconstructedConverted.precomposedStringWithCanonicalMapping
        guard let produced = producedText?.precomposedStringWithCanonicalMapping else {
            return ReconciledKeyText(
                original: original,
                converted: converted,
                sourceWasOpposite: false,
                strokes: strokes
            )
        }
        if produced == converted, produced != original {
            return ReconciledKeyText(
                original: converted,
                converted: original,
                sourceWasOpposite: true,
                strokes: strokes?.map {
                    PhysicalKeyStroke(
                        literal: $0.opposite,
                        opposite: $0.literal,
                        keyCode: $0.keyCode,
                        shift: $0.shift,
                        caps: $0.caps
                    )
                }
            )
        }
        return ReconciledKeyText(
            original: original,
            converted: converted,
            sourceWasOpposite: false,
            strokes: strokes
        )
    }
}
