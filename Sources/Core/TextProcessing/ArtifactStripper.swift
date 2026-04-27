import Foundation

/// Strips common ASR artifacts from transcription output.
///
/// Handles Whisper hallucinations, bracketed noise markers, and non-ASCII
/// ratio checks for Latin-script languages.
public enum ArtifactStripper {

    // MARK: - Known Whisper hallucinations

    /// Strings that appear in Whisper output due to multilingual training data.
    private static let whisperHallucinations: [String] = [
        "Să vă mulțumim pentru vizionare",
        "Subtitles by the Amara.org",
        "Untertitel der Amara.org",
        "Abonnez-vous à la chaîne",
        "ご視聴ありがとうございました",
        "字幕by有志",
        "Подписывайтесь на канал",
        "Amara.org community",
    ]

    // MARK: - Public API

    /// Strip bracketed artifacts, hallucinations, and suspicious character ratios.
    ///
    /// - Parameters:
    ///   - text: Raw transcription output.
    ///   - language: The active language; used for non-ASCII ratio check on Latin-script languages.
    /// - Returns: Cleaned text, or `""` if the result is entirely an artifact.
    public static func strip(_ text: String, language: SupportedLanguage = .english) -> String {
        let result = text
            .replacingOccurrences(of: #"\[.*?\]|\(.*?\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"  +"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"([.!?])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !result.isEmpty else { return result }

        for pattern in whisperHallucinations {
            if result.localizedCaseInsensitiveContains(pattern) { return "" }
        }

        if language.isLatinScript {
            let nonASCIICount = result.unicodeScalars.filter { $0.value > 127 }.count
            let ratio = Double(nonASCIICount) / Double(result.unicodeScalars.count)
            if ratio > 0.4 { return "" }
        }

        return result
    }

    /// Join transcription segments, normalising inconsistent leading/trailing spaces.
    public static func joinSegments(_ segments: [String]) -> String {
        segments
            .map { $0.trimmingCharacters(in: .init(charactersIn: " ")) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
