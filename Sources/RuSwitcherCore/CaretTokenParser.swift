import Foundation

public enum CaretTokenParser {
    /// Finds the final non-whitespace token and keeps whitespace between it and
    /// the caret. The caller still verifies this exact suffix before mutation.
    public static func tokenBeforeCaret(
        from suffix: String,
        tokenAtInputStartIsComplete: Bool = true
    ) -> (word: String, trailingWhitespace: String)? {
        var end = suffix.endIndex
        while end > suffix.startIndex {
            let previous = suffix.index(before: end)
            let character = suffix[previous]
            if character == " " {
                end = previous
            } else if character.isWhitespace {
                return nil
            } else {
                break
            }
        }
        let trailingWhitespace = String(suffix[end...])
        guard end > suffix.startIndex else { return nil }

        var start = end
        while start > suffix.startIndex {
            let previous = suffix.index(before: start)
            if suffix[previous].isWhitespace { break }
            start = previous
        }
        let word = String(suffix[start..<end])
        guard start > suffix.startIndex || tokenAtInputStartIsComplete else { return nil }
        guard !word.isEmpty, word.contains(where: \.isLetter) else { return nil }
        return (word, trailingWhitespace)
    }
}
