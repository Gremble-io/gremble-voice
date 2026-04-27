import FluidAudio
import Foundation
import GrembleVoiceCore
import os

/// Real-time streaming ASR engine backed by FluidAudio's Parakeet TDT model.
///
/// The caller feeds raw 16kHz mono Float32 samples via `addSamples(_:)` — typically
/// extracted inside an `AVAudioEngine` tap in the host app. The engine polls the
/// accumulated buffer every `config.pollingIntervalNs` nanoseconds, transcribes a
/// sliding window, and emits `StreamingTextUpdate` events via `textUpdates`.
///
/// Typical flow:
/// ```swift
/// let engine = ParakeetStreamingEngine()
/// try await engine.loadModel { _ in }
/// try await engine.startStreaming(config: .dictation)
///
/// for await update in await engine.textUpdates {
///     // update.confirmedText — stable words
///     // update.unconfirmedText — may change on next pass
/// }
///
/// let final = try await engine.stopStreaming()
/// ```
public actor ParakeetStreamingEngine: StreamingASREngine {

    // MARK: - ASREngine

    public let engineName = "Parakeet TDT v3 (streaming)"

    public private(set) var isModelLoaded = false

    // MARK: - Private state

    private let modelManager: ParakeetModelManager
    private var audioBuffer: AudioSampleBuffer?
    private var streamingTask: Task<Void, Never>?
    private var _textUpdates: AsyncStream<StreamingTextUpdate>?
    private var continuation: AsyncStream<StreamingTextUpdate>.Continuation?

    private let log = Logger(subsystem: "io.gremble.gremblevoice", category: "ParakeetStreamingEngine")

    // MARK: - Init

    public init() {
        self.modelManager = ParakeetModelManager()
    }

    public init(modelManager: ParakeetModelManager) {
        self.modelManager = modelManager
    }

    // MARK: - Lifecycle

    public func loadModel(progressHandler: @escaping @Sendable (Double) -> Void) async throws {
        try await modelManager.loadModel(progressHandler: progressHandler)
        isModelLoaded = true
    }

    public func unloadModel() async {
        await stopStreamingInternal()
        await modelManager.unloadModel()
        isModelLoaded = false
    }

    // MARK: - Batch transcription (required by ASREngine)

    public func transcribe(samples: [Float]) async throws -> TranscriptionResult {
        guard let asr = await modelManager.asrManager else {
            throw ASREngineError.modelNotLoaded
        }
        let start = Date()
        let result = try await asr.transcribe(samples, source: .microphone)
        let elapsed = Date().timeIntervalSince(start)
        return TranscriptionResult(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: result.confidence,
            processingTime: elapsed
        )
    }

    public func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        let samples = try AudioResampler.resampleFile(at: audioURL)
        return try await transcribe(samples: samples)
    }

    // MARK: - StreamingASREngine

    public func startStreaming(config: StreamingConfig) async throws {
        guard await modelManager.isModelLoaded else {
            throw ASREngineError.modelNotLoaded
        }

        // Tear down any previous session
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

                // Cap at maxBufferSamples to keep each pass fast
                let samples = allSamples.count > capturedConfig.maxBufferSamples
                    ? Array(allSamples.suffix(capturedConfig.maxBufferSamples))
                    : allSamples

                guard let asr = await capturedManager.asrManager else { continue }

                do {
                    let result = try await asr.transcribe(samples, source: .microphone)
                    let current = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
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

        log.info("Streaming started (maxBuffer=\(config.maxBufferSamples) minSamples=\(config.minSamples))")
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
        // Capture the last confirmed + unconfirmed text from the final stream event.
        // We'll do one last transcription pass on whatever is in the buffer.
        var finalText = ""
        if let asr = await modelManager.asrManager,
           let buffer = audioBuffer {
            let remaining = await buffer.consume()
            if remaining.count >= 1600 {  // at least 0.1s
                let result = try? await asr.transcribe(remaining, source: .microphone)
                finalText = result?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
        }

        await stopStreamingInternal()
        log.info("Streaming stopped. Final text: \"\(finalText.prefix(80))\"")
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
}
