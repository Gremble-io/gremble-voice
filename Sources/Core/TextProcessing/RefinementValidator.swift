import Foundation
import os

/// Validates LLM refinement output before replacing the original transcription.
///
/// Guards against runaway length, hallucinated content, and filler-word-only inputs
/// that aren't worth sending to the refiner.
public enum RefinementValidator {

    private static let log = Logger(subsystem: "io.gremble.gremblevoice", category: "RefinementValidator")

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
        guard !result.isEmpty else {
            log.info("Validation: fallback (empty result)")
            return .fallback(reason: "empty result")
        }

        // Length check
        let lengthLimit = original.count * (isStructuredContext ? 3 : 2) + 100
        let lengthRatio = Double(result.count) / Double(max(original.count, 1))
        if result.count > lengthLimit {
            log.warning("Validation: fallback length_anomaly result=\(result.count) limit=\(lengthLimit) ratio=\(String(format: "%.1f", lengthRatio))x")
            return .fallback(reason: "length anomaly (\(result.count) > \(lengthLimit))")
        }

        // Repetition loop detection: if any 2-word phrase appears 3+ times,
        // the model is stuck in a degenerate loop.
        if let guard_ = repetitionCheck(result: result) {
            return guard_
        }

        // Question-form preservation: if the input starts with an auxiliary/question
        // word, the output must preserve that word at the start (capitalized).
        // Catches the 3B model's tendency to invert subject-verb order in questions.
        if let guard_ = questionFormCheck(result: result, original: original) {
            return guard_
        }

        // Word overlap — only for inputs with > 5 content words
        let originalContent = normalizedWordSet(original, excludeFillers: true)
        if originalContent.count > 5 {
            let resultWords = normalizedWordSet(result, excludeFillers: false)
            let shared = originalContent.intersection(resultWords)
            let overlap = Double(shared.count) / Double(originalContent.count)
            if overlap < 0.5 {
                let missing = originalContent.subtracting(resultWords)
                log.warning("Validation: fallback overlap=\(Int(overlap * 100))% missing=\(Array(missing.prefix(5)))")
                return .fallback(reason: "word overlap too low (\(Int(overlap * 100))%)")
            }
            log.info("Validation: accept length_ratio=\(String(format: "%.1f", lengthRatio))x overlap=\(Int(overlap * 100))% content_words=\(originalContent.count)")
        } else {
            log.info("Validation: accept (short input, \(originalContent.count) content words) length_ratio=\(String(format: "%.1f", lengthRatio))x")
        }

        return .accept
    }

    // MARK: - Helpers

    /// Detect degenerate repetition loops (e.g. "the first two, the first two, the first two").
    private static func repetitionCheck(result: String) -> ValidationResult? {
        let words = result.lowercased()
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard words.count >= 6 else { return nil }

        for n in 2...min(4, words.count / 3) {
            var counts: [String: Int] = [:]
            for i in 0...(words.count - n) {
                let gram = words[i..<(i + n)].joined(separator: " ")
                counts[gram, default: 0] += 1
                if counts[gram]! >= 3 {
                    log.warning("Validation: fallback repetition_loop gram=\"\(gram)\" count=\(counts[gram]!)")
                    return .fallback(reason: "repetition loop (\(gram) ×\(counts[gram]!))")
                }
            }
        }
        return nil
    }

    /// Auxiliary and interrogative words that start questions in conversational speech.
    private static let questionStartWords: Set<String> = [
        "did", "do", "does", "can", "could", "would", "should", "will",
        "have", "has", "is", "are", "were", "was", "what", "when",
        "where", "who", "why", "how",
    ]

    /// Check whether a question-phrased input had its question form mangled.
    private static func questionFormCheck(result: String, original: String) -> ValidationResult? {
        let origWords = original.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .map(String.init)
            .filter { !fillerWords.contains($0) }
        guard let firstWord = origWords.first,
              questionStartWords.contains(firstWord) else { return nil }

        let resultFirstWord = result.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map { String($0).lowercased() } ?? ""

        if resultFirstWord != firstWord {
            log.warning("Validation: fallback question_reordered original_start=\"\(firstWord)\" result_start=\"\(resultFirstWord)\"")
            return .fallback(reason: "question reordered (\(firstWord)... → \(resultFirstWord)...)")
        }
        return nil
    }

    /// Minimal rule-based fixup for question inputs that failed refinement.
    /// Capitalizes the first letter and appends "?" if missing.
    public static func fixUpQuestion(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return t }
        let first = t.removeFirst()
        t = String(first).uppercased() + t
        if !t.hasSuffix("?") {
            if t.hasSuffix(".") || t.hasSuffix(",") {
                t = String(t.dropLast()) + "?"
            } else {
                t += "?"
            }
        }
        return t
    }

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
