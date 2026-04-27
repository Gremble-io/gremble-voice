import Foundation

/// Provides phonetic matching using multiple algorithms for robust word matching.
///
/// Used by `DictionaryProcessor` to catch misheard words that sound like
/// dictionary entries even when spelled differently.
public final class PhoneticMatcher: Sendable {

    /// Minimum normalized Levenshtein similarity (0–1) for fuzzy matching.
    private let minSimilarityScore: Double = 0.7

    public init() {}

    // MARK: - Public API

    /// Replace words in `text` that phonetically match `target`.
    ///
    /// - Parameters:
    ///   - text: The input text to process.
    ///   - target: The correct word to substitute in.
    ///   - pronunciation: Optional phonetic hint (overrides `target` for matching).
    /// - Returns: Text with phonetically similar words replaced by `target`.
    public func replacePhoneticMatches(in text: String, target: String, pronunciation: String?) -> String {
        let words = text.components(separatedBy: .whitespaces)
        let matchKey = pronunciation ?? target

        let targetSoundex = soundex(matchKey)
        let targetMetaphone = metaphone(matchKey)

        guard !targetSoundex.isEmpty || !targetMetaphone.isEmpty else { return text }

        var result: [String] = []

        for word in words {
            let (prefix, core, suffix) = extractPunctuation(from: word)

            guard core.lowercased() != target.lowercased() else {
                result.append(word)
                continue
            }

            if isPhoneticMatch(word: core, target: target, matchKey: matchKey,
                               targetSoundex: targetSoundex, targetMetaphone: targetMetaphone) {
                result.append("\(prefix)\(target)\(suffix)")
            } else {
                result.append(word)
            }
        }

        return result.joined(separator: " ")
    }

    // MARK: - Matching Strategies

    private func isPhoneticMatch(word: String, target: String, matchKey: String,
                                  targetSoundex: String, targetMetaphone: String) -> Bool {
        let wordLower = word.lowercased()
        let targetLower = target.lowercased()

        // Strategy 1: Soundex
        let wordSoundex = soundex(word)
        if !wordSoundex.isEmpty && wordSoundex == targetSoundex && isLengthSimilar(word, to: target) {
            return true
        }

        // Strategy 2: Metaphone
        let wordMetaphone = metaphone(word)
        if !wordMetaphone.isEmpty && wordMetaphone == targetMetaphone && isLengthSimilar(word, to: target) {
            return true
        }

        // Strategy 3: Levenshtein similarity
        let similarity = normalizedLevenshteinSimilarity(wordLower, targetLower)
        if similarity >= minSimilarityScore {
            return true
        }

        // Strategy 4: Weak phonetic + moderate Levenshtein
        let soundexSimilarity = normalizedLevenshteinSimilarity(wordSoundex, targetSoundex)
        let metaphoneSimilarity = normalizedLevenshteinSimilarity(wordMetaphone, targetMetaphone)
        if (soundexSimilarity >= 0.75 || metaphoneSimilarity >= 0.75) && similarity >= 0.6 {
            return true
        }

        return false
    }

    // MARK: - Punctuation Extraction

    private func extractPunctuation(from word: String) -> (prefix: String, core: String, suffix: String) {
        var prefix = ""
        var suffix = ""
        var core = word

        while let first = core.first, first.isPunctuation {
            prefix.append(first)
            core.removeFirst()
        }
        while let last = core.last, last.isPunctuation {
            suffix = String(last) + suffix
            core.removeLast()
        }

        return (prefix, core, suffix)
    }

    private func isLengthSimilar(_ word1: String, to word2: String) -> Bool {
        guard !word1.isEmpty && !word2.isEmpty else { return false }
        let ratio = Double(min(word1.count, word2.count)) / Double(max(word1.count, word2.count))
        return ratio >= 0.8
    }

    // MARK: - Soundex

    /// Classic Soundex — 4-character phonetic code.
    public func soundex(_ string: String) -> String {
        let normalized = string.lowercased().filter { $0.isLetter }
        guard let first = normalized.first else { return "" }

        let mapping: [Character: Character] = [
            "b": "1", "f": "1", "p": "1", "v": "1",
            "c": "2", "g": "2", "j": "2", "k": "2", "q": "2", "s": "2", "x": "2", "z": "2",
            "d": "3", "t": "3",
            "l": "4",
            "m": "5", "n": "5",
            "r": "6",
        ]

        var code = String(first).uppercased()
        var lastCode: Character? = mapping[first]

        for char in normalized.dropFirst() {
            if let digit = mapping[char], digit != lastCode {
                code.append(digit)
                lastCode = digit
            } else if mapping[char] == nil {
                lastCode = nil
            }
            if code.count == 4 { break }
        }

        while code.count < 4 { code.append("0") }
        return code
    }

    // MARK: - Metaphone

    /// Simplified English Metaphone — more accurate than Soundex for English.
    public func metaphone(_ string: String) -> String {
        let normalized = string.lowercased().filter { $0.isLetter }
        guard !normalized.isEmpty else { return "" }

        var result = ""
        let chars = Array(normalized)
        var i = 0

        if chars.count >= 2 {
            let prefix = String(chars.prefix(2))
            switch prefix {
            case "kn", "gn", "pn", "ae", "wr": i = 1
            case "wh": result.append("W"); i = 2
            default: break
            }
        }

        if i == 0 && chars[0] == "x" {
            result.append("S")
            i = 1
        }

        while i < chars.count {
            let char = chars[i]
            let prev = i > 0 ? chars[i - 1] : nil
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            let nextNext = i + 2 < chars.count ? chars[i + 2] : nil

            if char == prev { i += 1; continue }

            switch char {
            case "a", "e", "i", "o", "u":
                if i == 0 || (i == 1 && result.isEmpty) {
                    result.append(Character(char.uppercased()))
                }
            case "b":
                if !(prev == "m" && next == nil) { result.append("P") }
            case "c":
                if next == "i" || next == "e" || next == "y" { result.append("S") }
                else if next == "h" { result.append("X"); i += 1 }
                else { result.append("K") }
            case "d":
                if next == "g" && (nextNext == "e" || nextNext == "y" || nextNext == "i") {
                    result.append("J"); i += 1
                } else { result.append("T") }
            case "f": result.append("F")
            case "g":
                if next == "h" {
                    if nextNext != nil && !"aeiou".contains(nextNext!) { i += 1 }
                    else { result.append("F"); i += 1 }
                } else if next == "n" && nextNext == nil { break }
                else if next == "i" || next == "e" || next == "y" { result.append("J") }
                else { result.append("K") }
            case "h":
                if let next, "aeiou".contains(next), prev == nil || !"aeiou".contains(prev!) {
                    result.append("H")
                }
            case "j": result.append("J")
            case "k":
                if prev != "c" { result.append("K") }
            case "l": result.append("L")
            case "m": result.append("M")
            case "n": result.append("N")
            case "p":
                if next == "h" { result.append("F"); i += 1 }
                else { result.append("P") }
            case "q": result.append("K")
            case "r": result.append("R")
            case "s":
                if next == "h" { result.append("X"); i += 1 }
                else if next == "i" && (nextNext == "o" || nextNext == "a") { result.append("X") }
                else { result.append("S") }
            case "t":
                if next == "i" && (nextNext == "o" || nextNext == "a") { result.append("X") }
                else if next == "h" { result.append("0"); i += 1 }
                else if !(next == "c" && nextNext == "h") { result.append("T") }
            case "v": result.append("F")
            case "w":
                if let next, "aeiou".contains(next) { result.append("W") }
            case "x": result.append("KS")
            case "y":
                if let next, "aeiou".contains(next) { result.append("Y") }
            case "z": result.append("S")
            default: break
            }

            i += 1
        }

        return result
    }

    // MARK: - Levenshtein

    /// Edit distance between two strings.
    public func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1), b = Array(s2)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)

        for i in 0..<a.count {
            curr[0] = i + 1
            for j in 0..<b.count {
                curr[j + 1] = min(
                    prev[j + 1] + 1,
                    curr[j] + 1,
                    prev[j] + (a[i] == b[j] ? 0 : 1)
                )
            }
            prev = curr
        }
        return prev[b.count]
    }

    /// Normalized similarity in [0, 1] where 1.0 means identical.
    public func normalizedLevenshteinSimilarity(_ s1: String, _ s2: String) -> Double {
        if s1.isEmpty && s2.isEmpty { return 1.0 }
        if s1.isEmpty || s2.isEmpty { return 0.0 }
        let distance = levenshteinDistance(s1, s2)
        return 1.0 - (Double(distance) / Double(max(s1.count, s2.count)))
    }
}
