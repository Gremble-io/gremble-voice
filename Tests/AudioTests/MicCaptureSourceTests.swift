import XCTest
@testable import GrembleVoiceAudio
import GrembleVoiceCore

/// Unit tests for `MicCaptureSource` that do not require a real microphone.
///
/// Full mic capture requires hardware + entitlements and is not exercised here.
/// The debug app and integration environment cover the live capture path.
final class MicCaptureSourceTests: XCTestCase {

    // MARK: - Init

    func testDefaultSourceName() async {
        let mic = MicCaptureSource()
        let name = await mic.sourceName
        XCTAssertEqual(name, "Default Microphone")
    }

    func testIsCapturingFalseBeforeStart() async {
        let mic = MicCaptureSource()
        let capturing = await mic.isCapturing
        XCTAssertFalse(capturing)
    }

    func testStopBeforeStartIsNoop() async {
        let mic = MicCaptureSource()
        // Should not crash or throw.
        await mic.stop()
        let capturing = await mic.isCapturing
        XCTAssertFalse(capturing)
    }

    // MARK: - Device enumeration (delegates to AudioDeviceManager)

    func testAvailableInputDevicesReturnsArray() {
        // On any machine with audio hardware this should be non-empty.
        // On a headless CI box it may be empty — just verify it doesn't crash.
        let devices = AudioDeviceManager.availableInputDevices()
        XCTAssertNotNil(devices)
    }

    func testDeviceNameForInvalidIDReturnsNil() {
        // AudioDeviceID 0 is never a valid device.
        let name = AudioDeviceManager.deviceName(for: 0)
        XCTAssertNil(name)
    }

    func testDefaultInputDeviceIDIsConsistent() {
        // Two calls should return the same value (no hardware change between them).
        let first = AudioDeviceManager.defaultInputDeviceID()
        let second = AudioDeviceManager.defaultInputDeviceID()
        XCTAssertEqual(first, second)
    }
}
