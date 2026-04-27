import Foundation

/// Processes transcribed text using a personal pronunciation dictionary.
///
/// For each enabled entry, applies:
/// 1. Direct alias replacement (exact whole-word match, case-insensitive)
/// 2. Phonetic fuzzy matching via `PhoneticMatcher`
public final class DictionaryProcessor: Sendable {
    private let phoneticMatcher = PhoneticMatcher()

    public init() {}

    /// Apply dictionary replacements to `text`.
    ///
    /// - Parameters:
    ///   - text: The transcribed text to process.
    ///   - entries: Dictionary entries to use.
    ///   - language: Language code; only entries matching this language are applied.
    /// - Returns: Processed text with replacements applied.
    public func process(_ text: String, using entries: [DictionaryEntry], language: String) -> String {
        guard !text.isEmpty else { return text }

        let relevant = entries.filter { $0.language == language && $0.isEnabled }
        guard !relevant.isEmpty else { return text }

        var result = text

        for entry in relevant {
            for alias in entry.aliases {
                result = replaceWholeWord(in: result, find: alias, with: entry.word)
            }
            result = phoneticMatcher.replacePhoneticMatches(
                in: result,
                target: entry.word,
                pronunciation: entry.pronunciation
            )
        }

        return result
    }

    // MARK: - Private

    private func replaceWholeWord(in text: String, find: String, with replacement: String) -> String {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: find) + #"\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}
