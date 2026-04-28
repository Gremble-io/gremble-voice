import Testing
@testable import GrembleVoiceParakeet

@Suite("StreamingDiarizationEngine")
struct StreamingDiarizationEngineTests {

    @Test func notReadyOnInit() async {
        let engine = StreamingDiarizationEngine()
        let ready = await engine.isReady
        #expect(ready == false)
    }

    @Test func notReadyWithAllPresets() async {
        for preset in [
            StreamingDiarizationEngine.Preset.fast,
            .balanced,
            .highContext,
        ] {
            let engine = StreamingDiarizationEngine(preset: preset)
            let ready = await engine.isReady
            #expect(ready == false)
        }
    }

    @Test func stopSessionBeforeStartReturnsEmpty() async throws {
        let engine = StreamingDiarizationEngine()
        let segments = try await engine.stopSession()
        #expect(segments.isEmpty)
    }

    @Test func enrollSpeakerBeforePrepareThrows() async {
        let engine = StreamingDiarizationEngine()
        do {
            _ = try await engine.enrollSpeaker(name: "Alice", audioSamples: [0.1, 0.2, 0.3])
            Issue.record("Expected modelsNotPrepared error")
        } catch let error as StreamingDiarizationEngine.StreamingDiarizationError {
            guard case .modelsNotPrepared = error else {
                Issue.record("Expected .modelsNotPrepared, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func startSessionBeforePrepareThrows() async {
        let engine = StreamingDiarizationEngine()
        do {
            try await engine.startSession()
            Issue.record("Expected modelsNotPrepared error")
        } catch let error as StreamingDiarizationEngine.StreamingDiarizationError {
            guard case .modelsNotPrepared = error else {
                Issue.record("Expected .modelsNotPrepared, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func addAudioBeforePrepareDoesNotCrash() async {
        let engine = StreamingDiarizationEngine()
        await engine.addAudio([0.1, 0.2, 0.3, 0.4])
    }

    @Test func updatesReturnsFinishedStreamWhenNoSession() async {
        let engine = StreamingDiarizationEngine()
        let stream = await engine.updates
        var count = 0
        for await _ in stream {
            count += 1
        }
        #expect(count == 0)
    }
}
