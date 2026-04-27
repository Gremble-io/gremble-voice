import XCTest
@testable import GrembleVoiceCore

final class DictionaryProcessorTests: XCTestCase {
    var processor: DictionaryProcessor!

    override func setUp() {
        super.setUp()
        processor = DictionaryProcessor()
    }

    override func tearDown() {
        processor = nil
        super.tearDown()
    }

    private func entry(word: String, aliases: [String] = [], pronunciation: String? = nil) -> DictionaryEntry {
        DictionaryEntry(word: word, pronunciation: pronunciation, aliases: aliases, language: "en", isEnabled: true)
    }

    func testEmptyTextPassesThrough() {
        let result = processor.process("", using: [entry(word: "Test")], language: "en")
        XCTAssertEqual(result, "")
    }

    func testNoEntriesPassesThrough() {
        let result = processor.process("Hello world", using: [], language: "en")
        XCTAssertEqual(result, "Hello world")
    }

    func testDirectAliasReplacement() {
        let entries = [entry(word: "Anthropic", aliases: ["Antropik", "Anthropick"])]
        let result = processor.process("I work at Antropik", using: entries, language: "en")
        XCTAssertEqual(result, "I work at Anthropic")
    }

    func testAliasReplacementCaseInsensitive() {
        let entries = [entry(word: "Anthropic", aliases: ["antropik"])]
        let result = processor.process("I work at ANTROPIK today", using: entries, language: "en")
        XCTAssertEqual(result, "I work at Anthropic today")
    }

    func testAliasIsWholeWordOnly() {
        // "ant" alias should NOT match "anthropic"
        let entries = [entry(word: "Bug", aliases: ["ant"])]
        let result = processor.process("I love Anthropic", using: entries, language: "en")
        XCTAssertEqual(result, "I love Anthropic")
    }

    func testDisabledEntriesSkipped() {
        let disabled = DictionaryEntry(word: "Anthropic", aliases: ["Antropik"], language: "en", isEnabled: false)
        let result = processor.process("I work at Antropik", using: [disabled], language: "en")
        XCTAssertEqual(result, "I work at Antropik")
    }

    func testWrongLanguageEntriesSkipped() {
        let entries = [entry(word: "Anthropic", aliases: ["Antropik"])]
        // Processing with "fr" language should not apply English entries
        let result = processor.process("I work at Antropik", using: entries, language: "fr")
        XCTAssertEqual(result, "I work at Antropik")
    }

    func testMultipleEntriesApplied() {
        let entries = [
            entry(word: "Anthropic", aliases: ["Antropik"]),
            entry(word: "Claude", aliases: ["clod"]),
        ]
        let result = processor.process("Antropik made clod", using: entries, language: "en")
        XCTAssertEqual(result, "Anthropic made Claude")
    }
}
