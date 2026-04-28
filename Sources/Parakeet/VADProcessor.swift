import FluidAudio
import Foundation
import GrembleVoiceCore
import os

/// VAD-driven speech segment detector.
///
/// Wraps FluidAudio's `VadManager` and converts a continuous stream of 16kHz mono
/// Float32 samples into discrete speech segments, each of which is handed to the
/// caller via `onSpeechSegment`. Designed for meeting-transcription use cases where
/// accuracy matters more than latency.
///
/// Usage:
/// ```swift
/// let vad = VADProcessor(vadManager: try await modelManager.makeVadManager())
/// let hadFatalError = await vad.run(stream: sampleStream) { segment in
///     let result = try await parakeetEngine.transcribe(samples: segment)
///     print(result.text)
/// }
/// ```
public final class VADProcessor: @unchecked Sendable {

    /// Silero VAD expects chunks of exactly 4096 samples (256ms at 16kHz).
    public static let chunkSize = 4096

    /// Flush accumulated speech every 480,000 samples (~30s at 16kHz) during continuous speech.
    public static let flushInterval = 480_000

    /// Minimum speech segment length (8000 samples = 0.5s) before triggering transcription.
    public static let minSegmentSamples = 8_000

    /// How many consecutive VAD errors before the run loop aborts.
    public static let maxConsecutiveErrors = 10

    private let vadManager: VadManager
    private let log = Logger(subsystem: "io.gremble.gremblevoice", category: "VADProcessor")

    public init(vadManager: VadManager) {
        self.vadManager = vadManager
    }

    // MARK: - Run loop

    /// Process a stream of 16kHz mono Float32 samples using VAD-driven segmentation.
    ///
    /// - Parameters:
    ///   - stream: Continuous stream of `[Float]` sample chunks (any chunk size).
    ///   - onSpeechSegment: Called with each detected speech segment. May be called
    ///     concurrently — the caller is responsible for thread safety if needed.
    /// - Returns: `true` if the loop exited due to too many consecutive errors.
    @discardableResult
    public func run(
        stream: AsyncStream<[Float]>,
        onSpeechSegment: @Sendable ([Float]) async -> Void
    ) async -> Bool {
        var vadState = await vadManager.makeStreamState()
        var speechSamples: [Float] = []
        var vadBuffer: [Float] = []
        var isSpeaking = false
        var consecutiveErrors = 0

        loop: for await chunk in stream {
            vadBuffer.append(contentsOf: chunk)

            while vadBuffer.count >= Self.chunkSize {
                let vadChunk = Array(vadBuffer.prefix(Self.chunkSize))
                vadBuffer.removeFirst(Self.chunkSize)

                do {
                    let result = try await vadManager.processStreamingChunk(
                        vadChunk,
                        state: vadState,
                        config: .default,
                        returnSeconds: true,
                        timeResolution: 2
                    )
                    vadState = result.state
                    consecutiveErrors = 0

                    if let event = result.event {
                        switch event.kind {
                        case .speechStart:
                            isSpeaking = true
                            speechSamples.removeAll(keepingCapacity: true)
                            log.debug("Speech start detected")

                        case .speechEnd:
                            isSpeaking = false
                            log.debug("Speech end detected, samples=\(speechSamples.count)")
                            if speechSamples.count >= Self.minSegmentSamples {
                                let segment = speechSamples
                                speechSamples.removeAll(keepingCapacity: true)
                                await onSpeechSegment(segment)
                            } else {
                                speechSamples.removeAll(keepingCapacity: true)
                            }
                        }
                    }

                    if isSpeaking {
                        speechSamples.append(contentsOf: vadChunk)

                        // Flush every ~30s to prevent unbounded accumulation
                        if speechSamples.count >= Self.flushInterval {
                            let segment = speechSamples
                            speechSamples.removeAll(keepingCapacity: true)
                            await onSpeechSegment(segment)
                        }
                    }
                } catch {
                    log.error("VAD error: \(error.localizedDescription)")
                    consecutiveErrors += 1
                    if consecutiveErrors > Self.maxConsecutiveErrors {
                        log.error("Too many consecutive VAD errors — aborting")
                        break loop
                    }
                }
            }
        }

        // Flush any trailing speech at stream end
        if speechSamples.count >= Self.minSegmentSamples {
            await onSpeechSegment(speechSamples)
        }

        return consecutiveErrors > Self.maxConsecutiveErrors
    }
}
