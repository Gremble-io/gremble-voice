import Foundation
import GrembleVoiceCore

/// Persistent dictionary of user corrections.
///
/// Entries are saved as JSON in Application Support so they survive across
/// debug app launches. Each entry maps one or more "mis-heard" aliases to the
/// correct spelling, and is run through `DictionaryProcessor` before refinement.
@Observable
@MainActor
final class DictionaryStore {

    private(set) var entries: [DictionaryEntry] = []

    private let storageURL: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("GrembleVoiceDebug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appendingPathComponent("dictionary.json")
        load()
    }

    // MARK: - Mutations

    /// Add a new entry. `word` is the correct spelling; `alias` is how Parakeet heard it.
    func add(word: String, alias: String, language: String = "en") {
        // If an entry for this word already exists, append the alias instead of duplicating.
        if let idx = entries.firstIndex(where: {
            $0.word.lowercased() == word.lowercased() && $0.language == language
        }) {
            let existing = entries[idx]
            guard !existing.aliases.contains(where: { $0.lowercased() == alias.lowercased() }) else { return }
            entries[idx] = DictionaryEntry(
                id: existing.id,
                word: existing.word,
                pronunciation: existing.pronunciation,
                aliases: existing.aliases + [alias],
                language: existing.language,
                isEnabled: existing.isEnabled
            )
        } else {
            entries.append(DictionaryEntry(
                id: UUID(),
                word: word,
                pronunciation: nil,
                aliases: alias.isEmpty ? [] : [alias],
                language: language,
                isEnabled: true
            ))
        }
        save()
    }

    /// Toggle an entry's enabled state.
    func toggle(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let e = entries[idx]
        entries[idx] = DictionaryEntry(
            id: e.id, word: e.word, pronunciation: e.pronunciation,
            aliases: e.aliases, language: e.language, isEnabled: !e.isEnabled
        )
        save()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        entries = (try? JSONDecoder().decode([DictionaryEntry].self, from: data)) ?? []
    }

    private func save() {
        let data = try? JSONEncoder().encode(entries)
        try? data?.write(to: storageURL)
    }
}

// MARK: - Correction extraction

extension DictionaryStore {

    /// Compare `original` (raw transcript) with `edited` (user-corrected version)
    /// and return proposed `(alias, word)` pairs — i.e., what Parakeet said vs what
    /// the user intended.
    ///
    /// Uses a simple word-alignment pass: splits both into tokens, finds positions
    /// where they differ, and records single-word and two-word→one-word substitutions.
    static func extractCorrections(original: String, edited: String) -> [(alias: String, word: String)] {
        let origTokens = tokenize(original)
        let editTokens = tokenize(edited)

        var corrections: [(alias: String, word: String)] = []
        var o = 0
        var e = 0

        while o < origTokens.count && e < editTokens.count {
            let ow = origTokens[o]
            let ew = editTokens[e]

            if normalize(ow) == normalize(ew) {
                o += 1; e += 1
                continue
            }

            // Check for two-word → one-word collapse ("Gremble Voice" → "GrembleVoice")
            if o + 1 < origTokens.count {
                let twoWord = ow + " " + origTokens[o + 1]
                if normalize(twoWord) == normalize(ew) ||
                   stripped(twoWord) == stripped(ew) {
                    corrections.append((alias: twoWord, word: ew))
                    o += 2; e += 1
                    continue
                }
            }

            // Simple one-for-one substitution
            corrections.append((alias: ow, word: ew))
            o += 1; e += 1
        }

        return corrections.filter { $0.alias.lowercased() != $0.word.lowercased() }
    }

    private static func tokenize(_ text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }

    private static func normalize(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func stripped(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
