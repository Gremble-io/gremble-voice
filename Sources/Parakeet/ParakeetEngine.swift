import FluidAudio
import Foundation
import GrembleVoiceCore
import os

/// Batch ASR engine backed by FluidAudio's Parakeet TDT model.
///
/// For streaming transcription use `ParakeetStreamingEngine` instead.
/// Both share a single `ParakeetModelManager` to avoid loading the model twice.
public actor ParakeetEngine: ASREngine {

    // MARK: - ASREngine

    public let engineName = "Parakeet TDT v3"

    public private(set) var isModelLoaded = false

    // MARK: - Private state

    private let modelManager: ParakeetModelManager
    private let log = Logger(subsystem: "io.gremble.gremblevoice", category: "ParakeetEngine")

    // MARK: - Init

    /// Create a `ParakeetEngine` with a dedicated model manager.
    public init() {
        self.modelManager = ParakeetModelManager()
    }

    /// Create a `ParakeetEngine` that shares a model manager with other Parakeet components.
    ///
    /// Use this when you also create a `ParakeetStreamingEngine` — both share the same
    /// loaded model so memory is only allocated once.
    public init(modelManager: ParakeetModelManager) {
        self.modelManager = modelManager
    }

    // MARK: - Lifecycle

    public func loadModel(progressHandler: @escaping @Sendable (Double) -> Void) async throws {
        try await modelManager.loadModel(progressHandler: progressHandler)
        isModelLoaded = true
    }

    public func unloadModel() async {
        await modelManager.unloadModel()
        isModelLoaded = false
    }

    // MARK: - Transcription

    public func transcribe(samples: [Float]) async throws -> TranscriptionResult {
        try await transcribe(samples: samples, source: .microphone)
    }

    public func transcribe(
        samples: [Float],
        source: AudioStreamKind
    ) async throws -> TranscriptionResult {
        guard let asr = await modelManager.asrManager else {
            throw ASREngineError.modelNotLoaded
        }

        let layers = await asr.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: layers)

        let start = Date()
        let result = try await asr.transcribe(
            samples,
            decoderState: &decoderState
        )
        let elapsed = Date().timeIntervalSince(start)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        log.debug("Transcribed \(samples.count) samples → \"\(text.prefix(80))\" (\(String(format: "%.2f", elapsed))s)")

        let timings = result.tokenTimings?.map {
            WordTiming(word: $0.token, startTime: $0.startTime, endTime: $0.endTime, confidence: $0.confidence)
        }

        return TranscriptionResult(
            text: text,
            confidence: result.confidence,
            processingTime: elapsed,
            wordTimings: timings
        )
    }

    public func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        let samples = try AudioResampler.resampleFile(at: audioURL)
        return try await transcribe(samples: samples)
    }
}
