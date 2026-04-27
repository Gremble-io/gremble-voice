import XCTest
@testable import GrembleVoiceCore

final class WordDiffTests: XCTestCase {

    func testIdenticalStrings() {
        let (confirmed, unconfirmed) = WordDiff.diff(previous: "hello world", current: "hello world")
        XCTAssertEqual(confirmed, "hello world")
        XCTAssertEqual(unconfirmed, "")
    }

    func testEmptyPrevious() {
        let (confirmed, unconfirmed) = WordDiff.diff(previous: "", current: "hello world")
        XCTAssertEqual(confirmed, "")
        XCTAssertEqual(unconfirmed, "hello world")
    }

    func testEmptyCurrent() {
        let (confirmed, unconfirmed) = WordDiff.diff(previous: "hello world", current: "")
        XCTAssertEqual(confirmed, "")
        XCTAssertEqual(unconfirmed, "")
    }

    func testPartialMatch() {
        let (confirmed, unconfirmed) = WordDiff.diff(previous: "hello world", current: "hello earth")
        XCTAssertEqual(confirmed, "hello")
        XCTAssertEqual(unconfirmed, "earth")
    }

    func testNoPrefixMatch() {
        let (confirmed, unconfirmed) = WordDiff.diff(previous: "hello world", current: "goodbye world")
        XCTAssertEqual(confirmed, "")
        XCTAssertEqual(unconfirmed, "goodbye world")
    }

    func testCaseInsensitiveMatch() {
        let (confirmed, unconfirmed) = WordDiff.diff(previous: "Hello World", current: "hello world")
        XCTAssertEqual(confirmed, "hello world")
        XCTAssertEqual(unconfirmed, "")
    }

    func testPunctuationTolerant() {
        // Trailing punctuation should not prevent a word from being confirmed
        let (confirmed, unconfirmed) = WordDiff.diff(previous: "hello,", current: "hello, world")
        XCTAssertEqual(confirmed, "hello,")
        XCTAssertEqual(unconfirmed, "world")
    }

    func testNormalize() {
        XCTAssertEqual(WordDiff.normalize("Hello,"), "hello")
        XCTAssertEqual(WordDiff.normalize("world."), "world")
        XCTAssertEqual(WordDiff.normalize("GREAT!"), "great")
        XCTAssertEqual(WordDiff.normalize(""), "")
    }

    func testGrowingTranscript() {
        // Simulate a transcript that grows word by word
        let (c1, u1) = WordDiff.diff(previous: "the", current: "the quick")
        XCTAssertEqual(c1, "the")
        XCTAssertEqual(u1, "quick")

        let (c2, u2) = WordDiff.diff(previous: "the quick", current: "the quick brown")
        XCTAssertEqual(c2, "the quick")
        XCTAssertEqual(u2, "brown")
    }
}
