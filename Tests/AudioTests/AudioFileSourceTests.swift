import XCTest
@testable import GrembleVoiceAudio
import GrembleVoiceCore

final class AudioFileSourceTests: XCTestCase {

    private var testWAVURL: URL {
        // Resolve relative to the package root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AudioTests/
            .deletingLastPathComponent()   // Tests/
            .appendingPathComponent("Resources/test.wav")
    }

    // MARK: - Init

    func testSourceNameIsFileName() async {
        let url = URL(fileURLWithPath: "/tmp/my_recording.wav")
        let source = AudioFileSource(url: url)
        XCTAssertEqual(source.sourceName, "my_recording.wav")
    }

    func testIsCapturingFalseBeforeStart() async {
        let source = AudioFileSource(url: testWAVURL)
        let capturing = await source.isCapturing
        XCTAssertFalse(capturing)
    }

    // MARK: - start()

    func testStartYieldsSamples() async throws {
        let source = AudioFileSource(url: testWAVURL)
        let stream = try await source.start()

        var totalSamples = 0
        for await chunk in stream {
            XCTAssertFalse(chunk.isEmpty)
            totalSamples += chunk.count
        }
        XCTAssertGreaterThan(totalSamples, 0)
    }

    func testStartSetsIsCapturing() async throws {
        let source = AudioFileSource(url: testWAVURL)
        let stream = try await source.start()
        let capturing = await source.isCapturing
        XCTAssertTrue(capturing)
        _ = stream // keep stream alive until assertion is checked
    }

    func testChunksAreBoundedByChunkSize() async throws {
        let chunkSize = 512
        let source = AudioFileSource(url: testWAVURL, chunkSize: chunkSize)
        let stream = try await source.start()

        for await chunk in stream {
            XCTAssertLessThanOrEqual(chunk.count, chunkSize)
        }
    }

    func testSamplesAreFiniteFloats() async throws {
        let source = AudioFileSource(url: testWAVURL)
        let stream = try await source.start()

        outer: for await chunk in stream {
            for sample in chunk {
                XCTAssertTrue(sample.isFinite, "Non-finite sample: \(sample)")
                XCTAssertFalse(sample.isNaN)
            }
            break outer // One chunk is sufficient
        }
    }

    func testStopClearsIsCapturing() async throws {
        let source = AudioFileSource(url: testWAVURL)
        _ = try await source.start()
        await source.stop()
        let capturing = await source.isCapturing
        XCTAssertFalse(capturing)
    }

    func testDoubleStartThrows() async throws {
        let source = AudioFileSource(url: testWAVURL)
        let stream1 = try await source.start()
        do {
            _ = try await source.start()
            XCTFail("Expected captureFailure error")
        } catch AudioSourceError.captureFailure {
            // expected
        }
        _ = stream1 // keep first stream alive so isCapturing stays true
    }

    func testMissingFileThrows() async {
        let bad = URL(fileURLWithPath: "/nonexistent/file.wav")
        let source = AudioFileSource(url: bad)
        do {
            _ = try await source.start()
            XCTFail("Expected captureFailure error")
        } catch AudioSourceError.captureFailure {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
