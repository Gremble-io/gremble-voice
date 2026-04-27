import Foundation

/// Strips LLM preamble that small models sometimes prepend to their output.
///
/// Examples stripped:
/// - "Here is the cleaned text: ..."
/// - "Sure! Here's the refined version: ..."
/// - Triple-backtick or quote wrapping
public enum PreambleStripper {

    private static let preamblePatterns: [String] = [
        #"^(here'?s?( is)?( the)? (cleaned|refined|corrected|output|result)(ed)? (text|version|transcription|message):?\s*)"#,
        #"^(output|result|response|cleaned|refined):?\s*"#,
        #"^sure[!,.]? here( is|'s).*?:\s*"#,
        #"^certainly[,!.]? here.*?:\s*"#,
    ]

    /// Remove common LLM preamble and wrapper formatting from `text`.
    public static func strip(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip triple-backtick wrapping
        if result.hasPrefix("```") && result.hasSuffix("```") {
            result = result
                .replacingOccurrences(of: #"^```[^\n]*\n?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\n?```$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip quote wrapping
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 2 {
            result = String(result.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip common preamble patterns
        for pattern in preamblePatterns {
            if let range = result.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                result = String(result[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        return result
    }
}
