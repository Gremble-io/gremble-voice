import Foundation

/// A single entry in the personal pronunciation dictionary.
public struct DictionaryEntry: Sendable, Codable, Identifiable {
    public let id: UUID
    /// The correct word or phrase to use as a replacement.
    public let word: String
    /// Optional phonetic hint used to guide fuzzy matching (e.g., "grem-bull").
    public let pronunciation: String?
    /// Case-insensitive exact-match aliases that should also resolve to `word`.
    public let aliases: [String]
    /// BCP-47 language code this entry applies to (e.g., "en").
    public let language: String
    /// Whether this entry is active. Disabled entries are skipped.
    public let isEnabled: Bool

    public init(
        id: UUID = UUID(),
        word: String,
        pronunciation: String? = nil,
        aliases: [String] = [],
        language: String = "en",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.word = word
        self.pronunciation = pronunciation
        self.aliases = aliases
        self.language = language
        self.isEnabled = isEnabled
    }
}

/// All languages supported by Parakeet TDT v3.
public enum SupportedLanguage: String, Sendable, Codable, CaseIterable {
    case english = "en"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case italian = "it"
    case portuguese = "pt"
    case dutch = "nl"
    case polish = "pl"
    case romanian = "ro"
    case czech = "cs"
    case hungarian = "hu"
    case greek = "el"
    case bulgarian = "bg"
    case slovak = "sk"
    case danish = "da"
    case finnish = "fi"
    case swedish = "sv"
    case norwegian = "no"
    case croatian = "hr"
    case slovenian = "sl"
    case estonian = "et"
    case latvian = "lv"
    case lithuanian = "lt"
    case maltese = "mt"
    case irish = "ga"

    public var displayName: String {
        Locale.current.localizedString(forLanguageCode: rawValue) ?? rawValue.uppercased()
    }

    /// Whether this language uses a Latin-based script (used for hallucination detection).
    public var isLatinScript: Bool {
        switch self {
        case .greek, .bulgarian: return false
        default: return true
        }
    }

    public static var defaultLanguage: SupportedLanguage { .english }
}
