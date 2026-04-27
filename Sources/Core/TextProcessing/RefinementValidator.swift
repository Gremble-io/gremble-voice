import Foundation

/// Validates LLM refinement output before replacing the original transcription.
///
/// Guards against runaway length, hallucinated content, and filler-word-only inputs
/// that aren't worth sending to the refiner.
public enum RefinementValidator {

    /// Filler words excluded when counting "content" words for overlap checks.
    public static let fillerWords: Set<String> = [
        "um", "uh", "like", "you", "know", "basically", "so", "yeah", "mean", "right",
    ]

    // MARK: - Validation Result

    public enum ValidationResult: Sendable {
        /// Refinement output is acceptable — use it.
        case accept
        /// Refinement output is suspect — fall back to the original.
        case fallback(reason: String)
    }

    // MARK: - Public API

    /// Validate that `result` is a plausible refinement of `original`.
    ///
    /// - Parameters:
    ///   - result: The text returned by the refiner (already preamble-stripped).
    ///   - original: The raw transcription that was sent to the refiner.
    ///   - isStructuredContext: `true` when the active app is a code editor or notes app;
    ///     allows a larger length multiplier (3× vs 2×).
    public static func validate(
        result: String,
        original: String,
        isStructuredContext: Bool = false
    ) -> ValidationResult {
        guard !result.isEmpty else { return .fallback(reason: "empty result") }

        // Length check
        let lengthLimit = original.count * (isStructuredContext ? 3 : 2) + 100
        if result.count > lengthLimit {
            return .fallback(reason: "length anomaly (\(result.count) > \(lengthLimit))")
        }

        // Word overlap — only for inputs with > 5 content words
        let originalContent = normalizedWordSet(original, excludeFillers: true)
        if originalContent.count > 5 {
            let resultWords = normalizedWordSet(result, excludeFillers: false)
            let overlap = Double(originalContent.intersection(resultWords).count)
                        / Double(originalContent.count)
            if overlap < 0.5 {
                return .fallback(reason: "word overlap too low (\(Int(overlap * 100))%)")
            }
        }

        return .accept
    }

    // MARK: - Helpers

    /// Normalize text to a set of lowercase content words.
    public static func normalizedWordSet(_ text: String, excludeFillers: Bool) -> Set<String> {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: #"[^a-z0-9'\s]"#, with: "", options: .regularExpression)
        let words = Set(normalized.split(separator: " ").map(String.init).filter { !$0.isEmpty })
        return excludeFillers ? words.subtracting(fillerWords) : words
    }
}
