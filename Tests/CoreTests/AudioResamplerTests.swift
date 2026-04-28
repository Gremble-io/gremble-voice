import XCTest
@testable import GrembleVoiceCore

final class AudioResamplerTests: XCTestCase {

    private var testWAVURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/test.wav")
    }

    func testResampleFileProducesExpectedSampleCount() throws {
        let samples = try AudioResampler.resampleFile(at: testWAVURL)
        // test.wav is 5s at 16kHz — expect ~80,000 samples (allow ±1%)
        let expected = 80_000
        XCTAssertEqual(samples.count, expected, accuracy: 800,
                       "Sample count should be ~80,000 for a 5s 16kHz file")
    }

    func testResampleFileProducesFiniteFloats() throws {
        let samples = try AudioResampler.resampleFile(at: testWAVURL)
        XCTAssertFalse(samples.isEmpty, "Samples should not be empty")
        for sample in samples {
            XCTAssertTrue(sample.isFinite, "All samples must be finite Float32 values")
        }
    }

    func testResampleFileProducesNormalisedAmplitude() throws {
        let samples = try AudioResampler.resampleFile(at: testWAVURL)
        let maxAmplitude = samples.map(abs).max() ?? 0
        // 440Hz sine at 0.5 amplitude — expect peak well below 1.0
        XCTAssertLessThanOrEqual(maxAmplitude, 1.0, "Samples should be within [-1.0, 1.0]")
        XCTAssertGreaterThan(maxAmplitude, 0.0, "Signal should have non-zero amplitude")
    }

    func testTargetSampleRate() {
        XCTAssertEqual(AudioResampler.targetSampleRate, 16_000)
    }

    func testTargetFormatIsMonoFloat32() {
        let fmt = AudioResampler.targetFormat
        XCTAssertEqual(fmt.channelCount, 1)
        XCTAssertEqual(fmt.sampleRate, 16_000)
        XCTAssertEqual(fmt.commonFormat, .pcmFormatFloat32)
    }
}
