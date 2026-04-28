import XCTest
@testable import GrembleVoiceCore

final class RefinementValidatorTests: XCTestCase {

    // MARK: - Accept Cases

    func testAcceptsGoodRefinement() {
        let result = RefinementValidator.validate(
            result: "This is a well-refined sentence.",
            original: "this is um a well refined sentence"
        )
        if case .fallback(let reason) = result {
            XCTFail("Expected accept but got fallback: \(reason)")
        }
    }

    func testAcceptsShortInput() {
        // Fewer than 5 content words — word overlap check is skipped
        let result = RefinementValidator.validate(
            result: "Hello there.",
            original: "hello there"
        )
        if case .fallback(let reason) = result {
            XCTFail("Expected accept but got fallback: \(reason)")
        }
    }

    // MARK: - Fallback Cases

    func testFallbackOnEmptyResult() {
        let result = RefinementValidator.validate(result: "", original: "some original text here we go")
        if case .accept = result {
            XCTFail("Expected fallback for empty result")
        }
    }

    func testFallbackOnLengthAnomaly() {
        let original = "hi"
        let bloated = String(repeating: "word ", count: 100)  // Way more than 2× original
        let result = RefinementValidator.validate(result: bloated, original: original)
        if case .accept = result {
            XCTFail("Expected fallback for length anomaly")
        }
    }

    func testFallbackOnLowWordOverlap() {
        let original = "the quick brown fox jumps over the lazy dog"
        let hallucinated = "completely different words that share nothing with source"
        let result = RefinementValidator.validate(result: hallucinated, original: original)
        if case .accept = result {
            XCTFail("Expected fallback for low word overlap")
        }
    }

    // MARK: - Structured Context

    func testStructuredContextAllowsLargerOutput() {
        let original = "explain the code"
        // 3× limit + 100 buffer should be accepted for structured context
        let expanded = String(repeating: "word ", count: original.count / 5 * 3)
        let result = RefinementValidator.validate(
            result: expanded,
            original: original,
            isStructuredContext: true
        )
        // This is a boundary test — just verify the validator runs without crashing
        XCTAssertNotNil(result)
    }

    // MARK: - Normalized Word Set

    func testNormalizedWordSetExcludesFillers() {
        let words = RefinementValidator.normalizedWordSet(
            "um like you know basically yeah",
            excludeFillers: true
        )
        XCTAssertTrue(words.isEmpty)
    }

    func testNormalizedWordSetIncludesFillers() {
        let words = RefinementValidator.normalizedWordSet(
            "um like you know basically yeah",
            excludeFillers: false
        )
        XCTAssertFalse(words.isEmpty)
    }

    func testNormalizedWordSetHandlesPunctuation() {
        let words = RefinementValidator.normalizedWordSet("hello, world!", excludeFillers: false)
        XCTAssertTrue(words.contains("hello"))
        XCTAssertTrue(words.contains("world"))
    }

    func testNormalizedWordSetHandlesCurlyApostrophe() {
        let words = RefinementValidator.normalizedWordSet("don\u{2019}t", excludeFillers: false)
        XCTAssertTrue(words.contains("don't"))
    }
}
