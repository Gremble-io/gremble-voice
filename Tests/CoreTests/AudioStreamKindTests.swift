import XCTest
@testable import GrembleVoiceCore

final class AudioStreamKindTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(AudioStreamKind.microphone.rawValue, "microphone")
        XCTAssertEqual(AudioStreamKind.system.rawValue, "system")
    }

    func testInitFromRawValue() {
        XCTAssertEqual(AudioStreamKind(rawValue: "microphone"), .microphone)
        XCTAssertEqual(AudioStreamKind(rawValue: "system"), .system)
        XCTAssertNil(AudioStreamKind(rawValue: "invalid"))
    }
}
