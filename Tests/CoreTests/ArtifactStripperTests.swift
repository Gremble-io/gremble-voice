import XCTest
@testable import GrembleVoiceCore

final class ArtifactStripperTests: XCTestCase {

    func testStripsSquareBracketedArtifacts() {
        XCTAssertEqual(ArtifactStripper.strip("[Silence]"), "")
        XCTAssertEqual(ArtifactStripper.strip("[BLANK_AUDIO]"), "")
        XCTAssertEqual(ArtifactStripper.strip("Hello [Silence] world"), "Hello world")
    }

    func testStripsParenthesizedArtifacts() {
        XCTAssertEqual(ArtifactStripper.strip("(Music)"), "")
        XCTAssertEqual(ArtifactStripper.strip("Hello (Music) world"), "Hello world")
    }

    func testStripsMultipleArtifacts() {
        XCTAssertEqual(
            ArtifactStripper.strip("[Silence] Hello [BLANK_AUDIO] world (Music)"),
            "Hello world"
        )
    }

    func testCollapsesDoubleSpaces() {
        XCTAssertEqual(ArtifactStripper.strip("Hello  world"), "Hello world")
        XCTAssertEqual(ArtifactStripper.strip("Hello   world"), "Hello world")
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(ArtifactStripper.strip("  Hello world  "), "Hello world")
        XCTAssertEqual(ArtifactStripper.strip(" [Silence] Hello"), "Hello")
    }

    func testPassesThroughCleanText() {
        XCTAssertEqual(ArtifactStripper.strip("Hello world"), "Hello world")
        XCTAssertEqual(ArtifactStripper.strip(""), "")
    }

    func testHandlesOnlyArtifacts() {
        XCTAssertEqual(ArtifactStripper.strip("[Silence] [BLANK_AUDIO] (Music)"), "")
    }

    func testWhisperHallucinationDiscarded() {
        XCTAssertEqual(ArtifactStripper.strip("Subtitles by the Amara.org community"), "")
        XCTAssertEqual(ArtifactStripper.strip("Some text Amara.org community other text"), "")
    }

    func testNonASCIIRatioDiscardedForLatinScript() {
        // >40% non-ASCII in a Latin-script language → discarded.
        // Use a string where majority of characters are non-ASCII (ă repeats give >40% ratio).
        let highNonASCII = "ăăăăăă ab"  // 6 non-ASCII, 9 total = 67%
        XCTAssertEqual(ArtifactStripper.strip(highNonASCII, language: .english), "")
    }

    func testNonASCIIRatioPreservesNormalText() {
        // Romanian has diacritics but stays well below 40% in normal sentences → preserved
        let romanian = "Să vă ajutăm și să creăm ceva nou"  // ~18% non-ASCII
        XCTAssertFalse(ArtifactStripper.strip(romanian, language: .english).isEmpty)
    }

    func testJoinSegments() {
        XCTAssertEqual(ArtifactStripper.joinSegments(["Hello", "world"]), "Hello world")
        XCTAssertEqual(ArtifactStripper.joinSegments([" Hello ", " world "]), "Hello world")
        XCTAssertEqual(ArtifactStripper.joinSegments(["", "world", ""]), "world")
        XCTAssertEqual(ArtifactStripper.joinSegments([]), "")
    }
}
