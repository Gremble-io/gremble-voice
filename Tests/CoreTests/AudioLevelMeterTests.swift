import XCTest
@testable import GrembleVoiceCore

final class AudioLevelMeterTests: XCTestCase {

    func testRMSOfZeroSignal() {
        let samples = [Float](repeating: 0, count: 1024)
        XCTAssertEqual(AudioLevelMeter.rms(samples), 0, accuracy: 1e-6)
    }

    func testRMSOfConstantSignal() {
        // RMS of a constant c is c
        let samples = [Float](repeating: 0.5, count: 1024)
        XCTAssertEqual(AudioLevelMeter.rms(samples), 0.5, accuracy: 1e-5)
    }

    func testRMSOfSineWave() {
        // RMS of a full-scale sine wave is 1/√2 ≈ 0.7071
        let count = 16_000
        let samples: [Float] = (0..<count).map { i in
            Foundation.sin(2 * .pi * Float(i) / Float(count))
        }
        XCTAssertEqual(AudioLevelMeter.rms(samples), 1.0 / Foundation.sqrt(2.0), accuracy: 0.001)
    }

    func testRMSOfEmptyBuffer() {
        XCTAssertEqual(AudioLevelMeter.rms([]), 0)
    }

    func testPeakOfKnownSignal() {
        let samples: [Float] = [0.1, -0.5, 0.3, -0.8, 0.2]
        XCTAssertEqual(AudioLevelMeter.peak(samples), 0.8, accuracy: 1e-6)
    }

    func testPeakOfEmptyBuffer() {
        XCTAssertEqual(AudioLevelMeter.peak([]), 0)
    }

    func testToDBFS() {
        XCTAssertEqual(AudioLevelMeter.toDBFS(1.0), 0.0, accuracy: 1e-4)
        XCTAssertEqual(AudioLevelMeter.toDBFS(0.0), -160.0, accuracy: 1e-4)
        XCTAssertLessThan(AudioLevelMeter.toDBFS(0.5), 0)
    }
}
