import Foundation

public enum PhysicalBoundaryPolicy {
    /// A punctuation-looking key is not a reliable word boundary when the same
    /// physical key produces a letter in the other layout. For EN/RU this covers
    /// cases such as `.` -> `ю`, `,` -> `б` and `;` -> `ж`.
    public static func shouldDeferTerminalPunctuation(
        produced: Character,
        oppositeLayoutCharacter: Character?
    ) -> Bool {
        guard produced.unicodeScalars.allSatisfy({
            CharacterSet.punctuationCharacters.contains($0)
        }) else { return false }
        return oppositeLayoutCharacter?.isLetter == true
    }
}
