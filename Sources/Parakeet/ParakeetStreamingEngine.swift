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

    // VAD-gated mode (active when pollingIntervalNs == 0)
    private var vadManager: VadManager?
    private var vadState: VadStreamState?
    private var vadBuffer: [Float] = []
    private var isSpeaking = false

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
        let timings = result.tokenTimings?.map {
            WordTiming(word: $0.token, startTime: $0.startTime, endTime: $0.endTime, confidence: $0.confidence)
        }
        return TranscriptionResult(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: result.confidence,
            processingTime: elapsed,
            wordTimings: timings
        )
    }

    public func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        let samples = try AudioResampler.resampleFile(at: audioURL)
        return try await transcribe(samples: samples)
    }

    // MARK: - StreamingASREngine

    public func startStreaming(config: StreamingConfig) async throws {
        try await startStreaming(config: config, source: .microphone)
    }

    public func startStreaming(
        config: StreamingConfig,
        source: AudioStreamKind
    ) async throws {
        guard await modelManager.isModelLoaded else {
            throw ASREngineError.modelNotLoaded
        }

        // Tear down any previous session
        await stopStreamingInternal()

        // Initialize VAD for speech-gated mode
        if config.pollingIntervalNs == 0 {
            let vm = try await modelManager.makeVadManager()
            vadManager = vm
            vadState = await vm.makeStreamState()
            isSpeaking = false
            vadBuffer.removeAll()
            log.info("VAD-gated streaming enabled")
        }

        let buffer = AudioSampleBuffer()
        audioBuffer = buffer

        let (stream, cont) = AsyncStream<StreamingTextUpdate>.makeStream()
        _textUpdates = stream
        continuation = cont

        let capturedManager = modelManager
        let capturedConfig = config
        let capturedLog = log
        let pollNs = config.pollingIntervalNs > 0 ? config.pollingIntervalNs : 200_000_000

        streamingTask = Task {
            var previousText = ""
            let layerCount: Int = await capturedManager.asrManager?.decoderLayerCount ?? 2

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pollNs)

                let allSamples = await buffer.peek()
                guard allSamples.count >= capturedConfig.minSamples else { continue }

                // Cap at maxBufferSamples to keep each pass fast
                let samples = allSamples.count > capturedConfig.maxBufferSamples
                    ? Array(allSamples.suffix(capturedConfig.maxBufferSamples))
                    : allSamples

                guard let asr = await capturedManager.asrManager else { continue }

                do {
                    var decoderState = TdtDecoderState.make(decoderLayers: layerCount)
                    let result = try await asr.transcribe(
                        samples,
                        decoderState: &decoderState
                    )
                    let current = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !current.isEmpty else { continue }

                    let (confirmed, unconfirmed) = WordDiff.diff(previous: previousText, current: current)
                    previousText = current

                    let timings = result.tokenTimings?.map {
                        WordTiming(word: $0.token, startTime: $0.startTime, endTime: $0.endTime, confidence: $0.confidence)
                    }

                    capturedLog.debug("Streaming pass: \(samples.count) samples → \"\(current.prefix(60))\"")

                    cont.yield(StreamingTextUpdate(confirmedText: confirmed, unconfirmedText: unconfirmed, wordTimings: timings))
                } catch {
                    capturedLog.error("Streaming transcription error: \(error.localizedDescription)")
                }
            }
        }

        log.info("Streaming started (source=\(source.rawValue) maxBuffer=\(config.maxBufferSamples) minSamples=\(config.minSamples))")
    }

    public func addSamples(_ samples: [Float]) async {
        guard let audioBuffer else { return }

        if vadManager != nil {
            vadBuffer.append(contentsOf: samples)
            while vadBuffer.count >= VADProcessor.chunkSize {
                let chunk = Array(vadBuffer.prefix(VADProcessor.chunkSize))
                vadBuffer.removeFirst(VADProcessor.chunkSize)
                await processVADChunk(chunk, into: audioBuffer)
            }
        } else {
            await audioBuffer.append(samples)
        }
    }

    private func processVADChunk(_ chunk: [Float], into buffer: AudioSampleBuffer) async {
        guard let vadManager, let state = vadState else {
            await buffer.append(chunk)
            return
        }

        do {
            let result = try await vadManager.processStreamingChunk(
                chunk, state: state, config: .default, returnSeconds: true, timeResolution: 2
            )
            vadState = result.state

            if let event = result.event {
                switch event.kind {
                case .speechStart:
                    isSpeaking = true
                    log.debug("VAD: speech start")
                case .speechEnd:
                    isSpeaking = false
                    log.debug("VAD: speech end")
                }
            }

            if isSpeaking {
                await buffer.append(chunk)
            }
        } catch {
            // On VAD error, pass samples through to avoid losing audio
            await buffer.append(chunk)
        }
    }

    public var textUpdates: AsyncStream<StreamingTextUpdate> {
        get async {
            if let stream = _textUpdates { return stream }
            return AsyncStream { $0.finish() }
        }
    }

    public func stopStreaming() async throws -> String {
        var finalText = ""
        if let asr = await modelManager.asrManager,
           let buffer = audioBuffer {
            let remaining = await buffer.consume()
            if remaining.count >= 1600 {  // at least 0.1s
                let layers = await asr.decoderLayerCount
                var decoderState = TdtDecoderState.make(decoderLayers: layers)
                let result = try? await asr.transcribe(
                    remaining,
                    decoderState: &decoderState
                )
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

        vadManager = nil
        vadState = nil
        vadBuffer.removeAll()
        isSpeaking = false
    }
}
