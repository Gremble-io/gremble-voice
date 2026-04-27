import AVFoundation
import Foundation
import GrembleVoiceCore
import os
import WhisperKit

/// Batch ASR engine backed by WhisperKit.
///
/// For real-time streaming use `WhisperStreamingEngine` instead.
/// Both share a `WhisperModelManager` to avoid loading the model twice.
public actor WhisperEngine: ASREngine {

    // MARK: - ASREngine

    public let engineName: String
    public private(set) var isModelLoaded = false

    // MARK: - Private state

    private let modelManager: WhisperModelManager
    private let variant: String
    private let log = Logger(subsystem: "io.gremble.gremblevoice", category: "WhisperEngine")

    // MARK: - Init

    /// Create a `WhisperEngine` for the given model variant.
    ///
    /// - Parameter variant: WhisperKit model variant string, e.g. `"base.en"`,
    ///   `"small.en"`, `"large-v3-turbo"`. Defaults to `"base.en"`.
    public init(variant: String = "base.en") {
        self.variant = variant
        self.engineName = "Whisper \(variant)"
        self.modelManager = WhisperModelManager()
    }

    /// Create a `WhisperEngine` sharing a model manager with a `WhisperStreamingEngine`.
    public init(variant: String = "base.en", modelManager: WhisperModelManager) {
        self.variant = variant
        self.engineName = "Whisper \(variant)"
        self.modelManager = modelManager
    }

    // MARK: - Lifecycle

    public func loadModel(progressHandler: @escaping @Sendable (Double) -> Void) async throws {
        try await modelManager.loadModel(variant: variant, progressHandler: progressHandler)
        isModelLoaded = true
    }

    public func unloadModel() async {
        await modelManager.unloadModel()
        isModelLoaded = false
    }

    // MARK: - Transcription

    public func transcribe(audioURL: URL) async throws -> GrembleVoiceCore.TranscriptionResult {
        guard let wk = await modelManager.whisperKit else {
            throw ASREngineError.modelNotLoaded
        }

        let start = Date()
        let options = baseDecodingOptions(multilingual: await modelManager.isMultilingual)
        let results = try await wk.transcribe(audioPath: audioURL.path, decodeOptions: options)
        let elapsed = Date().timeIntervalSince(start)

        let text = joinSegments(results.compactMap(\.text))
        log.debug("Transcribed \(audioURL.lastPathComponent) → \"\(text.prefix(80))\" (\(String(format: "%.2f", elapsed))s)")

        return GrembleVoiceCore.TranscriptionResult(text: text, processingTime: elapsed)
    }

    public func transcribe(samples: [Float]) async throws -> GrembleVoiceCore.TranscriptionResult {
        guard let wk = await modelManager.whisperKit else {
            throw ASREngineError.modelNotLoaded
        }

        let start = Date()
        let options = baseDecodingOptions(multilingual: await modelManager.isMultilingual)
        let results = try await wk.transcribe(audioArray: samples, decodeOptions: options)
        let elapsed = Date().timeIntervalSince(start)

        let text = joinSegments(results.compactMap(\.text))
        log.debug("Transcribed \(samples.count) samples → \"\(text.prefix(80))\" (\(String(format: "%.2f", elapsed))s)")

        return GrembleVoiceCore.TranscriptionResult(text: text, processingTime: elapsed)
    }

    // MARK: - Helpers

    /// Greedy decoding options. Callers can build on top of these for language forcing etc.
    private func baseDecodingOptions(multilingual: Bool) -> DecodingOptions {
        var opts = DecodingOptions()
        opts.temperature = 0
        opts.temperatureFallbackCount = 0
        opts.skipSpecialTokens = true
        if multilingual {
            opts.detectLanguage = true
        }
        return opts
    }
}

/// Join WhisperKit result segments into a single trimmed string.
func joinSegments(_ segments: [String]) -> String {
    segments
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
