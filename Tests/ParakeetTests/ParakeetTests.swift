import XCTest
@testable import GrembleVoiceParakeet
import GrembleVoiceCore

// MARK: - ParakeetEngine

final class ParakeetEngineTests: XCTestCase {

    func testEngineNameIsParakeetTDT() async {
        let engine = ParakeetEngine()
        let name = await engine.engineName
        XCTAssertEqual(name, "Parakeet TDT v3")
    }

    func testModelNotLoadedOnInit() async {
        let engine = ParakeetEngine()
        let loaded = await engine.isModelLoaded
        XCTAssertFalse(loaded)
    }

    func testTranscribeThrowsWhenModelNotLoaded() async {
        let engine = ParakeetEngine()
        do {
            _ = try await engine.transcribe(samples: [0.0, 0.1, 0.2])
            XCTFail("Expected ASREngineError.modelNotLoaded")
        } catch is ASREngineError {
            // expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

// MARK: - ParakeetStreamingEngine

final class ParakeetStreamingEngineTests: XCTestCase {

    func testStreamingEngineNameIncludesStreaming() async {
        let engine = ParakeetStreamingEngine()
        let name = await engine.engineName
        XCTAssertTrue(name.contains("streaming"))
    }

    func testStreamingModelNotLoadedOnInit() async {
        let engine = ParakeetStreamingEngine()
        let loaded = await engine.isModelLoaded
        XCTAssertFalse(loaded)
    }

    func testStreamingTranscribeThrowsWhenModelNotLoaded() async {
        let engine = ParakeetStreamingEngine()
        do {
            _ = try await engine.transcribe(samples: [0.0])
            XCTFail("Expected ASREngineError.modelNotLoaded")
        } catch is ASREngineError {
            // expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

// MARK: - DiarizationEngine

final class DiarizationEngineTests: XCTestCase {

    func testNotReadyOnInit() async {
        let engine = DiarizationEngine()
        let ready = await engine.isReady
        XCTAssertFalse(ready)
    }

    func testProcessThrowsWhenModelsNotPrepared() async {
        let engine = DiarizationEngine()
        do {
            _ = try await engine.process(samples: [0.0, 0.1])
            XCTFail("Expected DiarizationError.modelsNotPrepared")
        } catch is DiarizationEngine.DiarizationError {
            // expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSegmentDurationComputed() {
        let segment = DiarizationEngine.Segment(
            speakerId: "SPEAKER_00",
            startTime: 1.5,
            endTime: 4.0
        )
        XCTAssertEqual(segment.duration, 2.5, accuracy: 0.001)
    }
}

// MARK: - VADProcessor

final class VADProcessorTests: XCTestCase {

    func testChunkSizeIs4096() {
        XCTAssertEqual(VADProcessor.chunkSize, 4096)
    }

    func testFlushIntervalIs30Seconds() {
        // 480,000 samples / 16,000 Hz = 30s
        XCTAssertEqual(VADProcessor.flushInterval, 480_000)
    }

    func testMinSegmentSamplesIsHalfSecond() {
        // 8,000 samples / 16,000 Hz = 0.5s
        XCTAssertEqual(VADProcessor.minSegmentSamples, 8_000)
    }
}
