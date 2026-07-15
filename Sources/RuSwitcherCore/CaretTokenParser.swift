import Foundation

public enum CaretTokenParser {
    /// Splits text immediately before the caret into the last non-whitespace
    /// token and any trailing whitespace that sits between that token and the caret.
    public static func tokenBeforeCaret(
        from suffix: String
    ) -> (word: String, trailingWhitespace: String)? {
        var end = suffix.endIndex
        while end > suffix.startIndex {
            let prev = suffix.index(before: end)
            if suffix[prev].isWhitespace { end = prev } else { break }
        }
        let trailingWhitespace = String(suffix[end...])
        guard end > suffix.startIndex else { return nil }

        var start = end
        while start > suffix.startIndex {
            let prev = suffix.index(before: start)
            let ch = suffix[prev]
            if ch.isWhitespace || ch.isNewline { break }
            start = prev
        }
        let word = String(suffix[start..<end])
        guard !word.isEmpty, word.contains(where: \.isLetter) else { return nil }
        return (word, trailingWhitespace)
    }
}
