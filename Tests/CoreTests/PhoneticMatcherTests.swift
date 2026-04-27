import XCTest
@testable import GrembleVoiceCore

final class PhoneticMatcherTests: XCTestCase {
    var matcher: PhoneticMatcher!

    override func setUp() {
        super.setUp()
        matcher = PhoneticMatcher()
    }

    override func tearDown() {
        matcher = nil
        super.tearDown()
    }

    // MARK: - Soundex

    func testSoundexBasicEncodings() {
        XCTAssertEqual(matcher.soundex("Robert"), "R163")
        XCTAssertEqual(matcher.soundex("Rupert"), "R163")
        XCTAssertEqual(matcher.soundex("Ashcraft"), "A226")
        XCTAssertEqual(matcher.soundex("Ashcroft"), "A226")
        XCTAssertEqual(matcher.soundex("Tymczak"), "T522")
        XCTAssertEqual(matcher.soundex("Pfister"), "P236")
    }

    func testSoundexSimilarNames() {
        XCTAssertEqual(matcher.soundex("Smith"), matcher.soundex("Smyth"))
        XCTAssertEqual(matcher.soundex("Johnson"), matcher.soundex("Jonson"))
        XCTAssertEqual(matcher.soundex("Peterson"), matcher.soundex("Petersen"))
    }

    func testSoundexEmptyAndShort() {
        XCTAssertEqual(matcher.soundex(""), "")
        XCTAssertEqual(matcher.soundex("A"), "A000")
        XCTAssertEqual(matcher.soundex("AB"), "A100")
    }

    func testSoundexCaseInsensitive() {
        XCTAssertEqual(matcher.soundex("ROBERT"), matcher.soundex("robert"))
        XCTAssertEqual(matcher.soundex("Robert"), matcher.soundex("rObErT"))
    }

    // MARK: - Metaphone

    func testMetaphoneBasicEncodings() {
        XCTAssertEqual(matcher.metaphone("phone"), "FN")
        XCTAssertEqual(matcher.metaphone("fone"), "FN")
    }

    func testMetaphoneSilentLetters() {
        XCTAssertEqual(matcher.metaphone("knight"), "NT")
        XCTAssertEqual(matcher.metaphone("night"), "NT")
        XCTAssertEqual(matcher.metaphone("write"), "RT")
        XCTAssertEqual(matcher.metaphone("right"), "RT")
    }

    func testMetaphonePhSoundsLikeF() {
        XCTAssertEqual(matcher.metaphone("phone"), matcher.metaphone("fone"))
    }

    func testMetaphoneEmpty() {
        XCTAssertEqual(matcher.metaphone(""), "")
    }

    // MARK: - Levenshtein Distance

    func testLevenshteinIdentical() {
        XCTAssertEqual(matcher.levenshteinDistance("hello", "hello"), 0)
        XCTAssertEqual(matcher.levenshteinDistance("", ""), 0)
    }

    func testLevenshteinEmpty() {
        XCTAssertEqual(matcher.levenshteinDistance("hello", ""), 5)
        XCTAssertEqual(matcher.levenshteinDistance("", "world"), 5)
    }

    func testLevenshteinSingleEdit() {
        XCTAssertEqual(matcher.levenshteinDistance("cat", "cats"), 1)
        XCTAssertEqual(matcher.levenshteinDistance("cats", "cat"), 1)
        XCTAssertEqual(matcher.levenshteinDistance("cat", "bat"), 1)
    }

    func testLevenshteinMultipleEdits() {
        XCTAssertEqual(matcher.levenshteinDistance("kitten", "sitting"), 3)
        XCTAssertEqual(matcher.levenshteinDistance("saturday", "sunday"), 3)
    }

    // MARK: - Normalized Similarity

    func testNormalizedSimilarityIdentical() {
        XCTAssertEqual(matcher.normalizedLevenshteinSimilarity("hello", "hello"), 1.0)
    }

    func testNormalizedSimilarityEmpty() {
        XCTAssertEqual(matcher.normalizedLevenshteinSimilarity("", ""), 1.0)
        XCTAssertEqual(matcher.normalizedLevenshteinSimilarity("hello", ""), 0.0)
        XCTAssertEqual(matcher.normalizedLevenshteinSimilarity("", "hello"), 0.0)
    }

    func testNormalizedSimilarityPartial() {
        let similarity = matcher.normalizedLevenshteinSimilarity("hello", "hallo")
        XCTAssertEqual(similarity, 0.8, accuracy: 0.01)
    }

    // MARK: - Phonetic Replacement

    func testReplacePhoneticMatchesBasic() {
        let result = matcher.replacePhoneticMatches(in: "I work at Antropik", target: "Anthropic", pronunciation: nil)
        XCTAssertEqual(result, "I work at Anthropic")
    }

    func testReplacePreservesPunctuation() {
        let result = matcher.replacePhoneticMatches(in: "Hello, Antropik!", target: "Anthropic", pronunciation: nil)
        XCTAssertEqual(result, "Hello, Anthropic!")
    }

    func testReplaceSkipsExactMatch() {
        let result = matcher.replacePhoneticMatches(in: "I work at Anthropic", target: "Anthropic", pronunciation: nil)
        XCTAssertEqual(result, "I work at Anthropic")
    }

    func testReplaceNoFalsePositives() {
        // "Atlantic" is too different from "Anthropic"
        let result = matcher.replacePhoneticMatches(in: "The Atlantic ocean", target: "Anthropic", pronunciation: nil)
        XCTAssertEqual(result, "The Atlantic ocean")
    }

    func testReplaceCommonMisspelling() {
        let result = matcher.replacePhoneticMatches(in: "Call Steven please", target: "Stephen", pronunciation: nil)
        XCTAssertEqual(result, "Call Stephen please")
    }
}
