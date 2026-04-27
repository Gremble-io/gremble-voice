import Foundation
import GrembleVoiceCore
import os
import WhisperKit

/// Real-time streaming ASR engine backed by WhisperKit.
///
/// Caller feeds 16kHz mono Float32 samples via `addSamples(_:)`. The engine polls
/// the accumulated buffer every `config.pollingIntervalNs` nanoseconds, transcribes
/// a sliding window via `transcribe(audioArray:)`, and emits `StreamingTextUpdate`
/// events via `textUpdates`.
///
/// The same pattern as `ParakeetStreamingEngine`: the audio tap lives in the host
/// app, not the engine.
public actor WhisperStreamingEngine: StreamingASREngine {

    // MARK: - ASREngine

    public let engineName: String
    public private(set) var isModelLoaded = false

    // MARK: - Private state

    private let modelManager: WhisperModelManager
    private let variant: String
    private var audioBuffer: AudioSampleBuffer?
    private var streamingTask: Task<Void, Never>?
    private var _textUpdates: AsyncStream<StreamingTextUpdate>?
    private var continuation: AsyncStream<StreamingTextUpdate>.Continuation?

    private let log = Logger(subsystem: "io.gremble.gremblevoice", category: "WhisperStreamingEngine")

    // MARK: - Init

    public init(variant: String = "base.en") {
        self.variant = variant
        self.engineName = "Whisper \(variant) (streaming)"
        self.modelManager = WhisperModelManager()
    }

    public init(variant: String = "base.en", modelManager: WhisperModelManager) {
        self.variant = variant
        self.engineName = "Whisper \(variant) (streaming)"
        self.modelManager = modelManager
    }

    // MARK: - Lifecycle

    public func loadModel(progressHandler: @escaping @Sendable (Double) -> Void) async throws {
        try await modelManager.loadModel(variant: variant, progressHandler: progressHandler)
        isModelLoaded = true
    }

    public func unloadModel() async {
        await stopStreamingInternal()
        await modelManager.unloadModel()
        isModelLoaded = false
    }

    // MARK: - Batch transcription (required by ASREngine)

    public func transcribe(samples: [Float]) async throws -> GrembleVoiceCore.TranscriptionResult {
        guard let wk = await modelManager.whisperKit else {
            throw ASREngineError.modelNotLoaded
        }
        let start = Date()
        let opts = streamingDecodingOptions(multilingual: await modelManager.isMultilingual)
        let results = try await wk.transcribe(audioArray: samples, decodeOptions: opts)
        let elapsed = Date().timeIntervalSince(start)
        let text = joinSegments(results.compactMap(\.text))
        return GrembleVoiceCore.TranscriptionResult(text: text, processingTime: elapsed)
    }

    public func transcribe(audioURL: URL) async throws -> GrembleVoiceCore.TranscriptionResult {
        guard let wk = await modelManager.whisperKit else {
            throw ASREngineError.modelNotLoaded
        }
        let start = Date()
        let opts = streamingDecodingOptions(multilingual: await modelManager.isMultilingual)
        let results = try await wk.transcribe(audioPath: audioURL.path, decodeOptions: opts)
        let elapsed = Date().timeIntervalSince(start)
        let text = joinSegments(results.compactMap(\.text))
        return GrembleVoiceCore.TranscriptionResult(text: text, processingTime: elapsed)
    }

    // MARK: - StreamingASREngine

    public func startStreaming(config: StreamingConfig) async throws {
        guard await modelManager.isModelLoaded else {
            throw ASREngineError.modelNotLoaded
        }

        await stopStreamingInternal()

        let buffer = AudioSampleBuffer()
        audioBuffer = buffer

        let (stream, cont) = AsyncStream<StreamingTextUpdate>.makeStream()
        _textUpdates = stream
        continuation = cont

        let capturedManager = modelManager
        let capturedConfig = config
        let capturedLog = log

        streamingTask = Task {
            var previousText = ""

            while !Task.isCancelled {
                if capturedConfig.pollingIntervalNs > 0 {
                    try? await Task.sleep(nanoseconds: capturedConfig.pollingIntervalNs)
                }

                let allSamples = await buffer.peek()
                guard allSamples.count >= capturedConfig.minSamples else { continue }

                let samples = allSamples.count > capturedConfig.maxBufferSamples
                    ? Array(allSamples.suffix(capturedConfig.maxBufferSamples))
                    : allSamples

                guard let wk = await capturedManager.whisperKit else { continue }
                let multilingual = await capturedManager.isMultilingual

                do {
                    let opts = streamingDecodingOptions(multilingual: multilingual)
                    let results = try await wk.transcribe(audioArray: samples, decodeOptions: opts)
                    let current = joinSegments(results.compactMap(\.text))
                    guard !current.isEmpty else { continue }

                    let (confirmed, unconfirmed) = WordDiff.diff(previous: previousText, current: current)
                    previousText = current

                    capturedLog.debug("Streaming pass: \(samples.count) samples → \"\(current.prefix(60))\"")
                    cont.yield(StreamingTextUpdate(confirmedText: confirmed, unconfirmedText: unconfirmed))
                } catch {
                    capturedLog.error("Streaming transcription error: \(error.localizedDescription)")
                }
            }
        }

        log.info("Streaming started (variant=\(self.variant) maxBuffer=\(config.maxBufferSamples))")
    }

    public func addSamples(_ samples: [Float]) async {
        await audioBuffer?.append(samples)
    }

    public var textUpdates: AsyncStream<StreamingTextUpdate> {
        get async {
            if let stream = _textUpdates { return stream }
            return AsyncStream { $0.finish() }
        }
    }

    public func stopStreaming() async throws -> String {
        // Final pass on any remaining buffer
        var finalText = ""
        if let wk = await modelManager.whisperKit,
           let buffer = audioBuffer {
            let remaining = await buffer.consume()
            if remaining.count >= 1600 {
                let opts = streamingDecodingOptions(multilingual: await modelManager.isMultilingual)
                let results = try? await wk.transcribe(audioArray: remaining, decodeOptions: opts)
                finalText = joinSegments((results ?? []).compactMap(\.text))
            }
        }

        await stopStreamingInternal()
        log.info("Streaming stopped. Final: \"\(finalText.prefix(80))\"")
        return finalText
    }

    // MARK: - Private

    private func stopStreamingInternal() async {
        streamingTask?.cancel()
        let task = streamingTask
        streamingTask = nil
        _ = await task?.value

        continuation?.finish()
        continuation = nil
        _textUpdates = nil
        audioBuffer = nil
    }

    private func streamingDecodingOptions(multilingual: Bool) -> DecodingOptions {
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
