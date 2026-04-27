import Foundation

/// Word-level common-prefix diff for streaming transcription overlays.
///
/// Words stable across consecutive transcription passes are "confirmed".
/// The remainder is "unconfirmed" and may change as more audio arrives.
public enum WordDiff {

    /// Compute confirmed and unconfirmed portions of `current` relative to `previous`.
    ///
    /// - Parameters:
    ///   - previous: The transcription from the previous pass.
    ///   - current: The transcription from the current pass.
    /// - Returns: `(confirmed, unconfirmed)` — both are space-joined word strings.
    public static func diff(previous: String, current: String) -> (confirmed: String, unconfirmed: String) {
        let previousWords = previous.split(separator: " ").map(String.init)
        let currentWords = current.split(separator: " ").map(String.init)

        var commonCount = 0
        let minCount = min(previousWords.count, currentWords.count)
        for i in 0..<minCount {
            if normalize(previousWords[i]) == normalize(currentWords[i]) {
                commonCount += 1
            } else {
                break
            }
        }

        let confirmed = currentWords.prefix(commonCount).joined(separator: " ")
        let unconfirmed = currentWords.dropFirst(commonCount).joined(separator: " ")
        return (confirmed: confirmed, unconfirmed: unconfirmed)
    }

    /// Lowercase and strip trailing punctuation for comparison.
    public static func normalize(_ word: String) -> String {
        var s = word.lowercased()
        while let last = s.last, last.isPunctuation {
            s.removeLast()
        }
        return s
    }

    // MARK: - Script Mode comparison

    /// Filler words that appear in ASR output but should NOT count as errors
    /// when comparing ASR output to a reference script.
    private static let fillerWords: Set<String> = [
        "uh", "um", "uh-huh", "uhh", "umm", "hmm", "hm",
        "like", "you know", "so", "well", "actually", "basically",
        "right", "okay", "ok"
    ]

    /// Count the number of meaningful word-level differences between ASR output
    /// and a reference script. Used in Script Mode to decide auto-include vs. review.
    ///
    /// Filler words present in `asr` but absent in `reference` are NOT counted
    /// as errors — they are expected ASR noise and valuable training signal.
    ///
    /// - Parameters:
    ///   - asr: Raw ASR output (may contain fillers, minor errors).
    ///   - reference: The intended reference script.
    /// - Returns: Number of non-filler word-level differences.
    public static func wordDifferences(between asr: String, and reference: String) -> Int {
        let asrWords = tokenize(asr)
        let refWords = tokenize(reference)

        // Filter out filler-word insertions from ASR before computing edit distance
        let asrFiltered = asrWords.filter { !fillerWords.contains($0) }

        return levenshteinDistance(asrFiltered, refWords)
    }

    /// Normalized threshold for auto-include in Script Mode.
    /// Returns the maximum number of word differences allowed for auto-include.
    public static func autoIncludeThreshold(for referenceText: String) -> Int {
        let wordCount = tokenize(referenceText).count
        return max(2, Int((Double(wordCount) * 0.05).rounded()))
    }

    // MARK: - Private helpers

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { word in
                // Strip leading/trailing punctuation
                var s = word
                while let first = s.first, first.isPunctuation { s.removeFirst() }
                while let last = s.last, last.isPunctuation { s.removeLast() }
                return s
            }
            .filter { !$0.isEmpty }
    }

    private static func levenshteinDistance(_ a: [String], _ b: [String]) -> Int {
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }

        var dp = Array(0...n)
        for i in 1...m {
            var prev = dp[0]
            dp[0] = i
            for j in 1...n {
                let temp = dp[j]
                dp[j] = a[i - 1] == b[j - 1]
                    ? prev
                    : 1 + min(prev, min(dp[j], dp[j - 1]))
                prev = temp
            }
        }
        return dp[n]
    }
}
