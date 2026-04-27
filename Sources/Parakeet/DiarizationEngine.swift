import FluidAudio
import Foundation
import os

/// A speaker diarization engine backed by FluidAudio's `OfflineDiarizerManager`.
///
/// Identifies "who spoke when" in a recorded audio file. Intended for
/// post-session processing — not real-time streaming.
///
/// Typical usage (post-session in a meeting transcription app):
/// ```swift
/// let diarizer = DiarizationEngine()
/// try await diarizer.prepareModels()
/// let segments = try await diarizer.process(audioURL: sessionURL)
/// for seg in segments {
///     print("\(seg.speakerId): \(seg.startTime)s → \(seg.endTime)s")
/// }
/// ```
public actor DiarizationEngine {

    /// A single speaker segment identified by diarization.
    public struct Segment: Sendable {
        /// Speaker label (e.g. "SPEAKER_00", "SPEAKER_01").
        public let speakerId: String
        /// Start time in seconds relative to the beginning of the audio.
        public let startTime: Float
        /// End time in seconds.
        public let endTime: Float
        /// Duration in seconds.
        public var duration: Float { endTime - startTime }
    }

    // MARK: - Private state

    // nonisolated(unsafe): OfflineDiarizerManager is a non-Sendable final class.
    // Access is serialised through the DiarizationEngine actor, so this is safe.
    private nonisolated(unsafe) var manager: OfflineDiarizerManager?
    private let log = Logger(subsystem: "io.gremble.gremblevoice", category: "DiarizationEngine")

    public init() {}

    // MARK: - Public API

    /// Whether models have been downloaded and prepared.
    public var isReady: Bool { manager != nil }

    /// Download (if needed) and prepare CoreML diarization models.
    ///
    /// Only needs to be called once per session — the models remain loaded.
    public func prepareModels() async throws {
        log.info("Preparing diarization models...")
        let m = OfflineDiarizerManager()
        try await m.prepareModels()
        manager = m
        log.info("Diarization models ready")
    }

    /// Run offline speaker diarization on an audio file.
    ///
    /// - Parameter audioURL: Path to any audio file readable by `AVAudioFile`.
    ///   The diarizer handles resampling internally.
    /// - Returns: Chronologically ordered speaker segments.
    public func process(audioURL: URL) async throws -> [Segment] {
        guard let m = manager else {
            throw DiarizationError.modelsNotPrepared
        }

        log.info("Running diarization on \(audioURL.lastPathComponent)")
        let result = try await m.process(audioURL)

        let segments = result.segments.map {
            Segment(
                speakerId: $0.speakerId,
                startTime: $0.startTimeSeconds,
                endTime: $0.endTimeSeconds
            )
        }

        log.info("Diarization complete: \(segments.count) segments, \(Set(segments.map(\.speakerId)).count) speakers")
        return segments
    }

    /// Run offline speaker diarization directly on audio samples.
    ///
    /// - Parameter samples: 16kHz mono Float32 audio.
    public func process(samples: [Float]) async throws -> [Segment] {
        guard let m = manager else {
            throw DiarizationError.modelsNotPrepared
        }

        log.info("Running diarization on \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16_000))s)")
        let result = try await m.process(audio: samples)

        return result.segments.map {
            Segment(
                speakerId: $0.speakerId,
                startTime: $0.startTimeSeconds,
                endTime: $0.endTimeSeconds
            )
        }
    }

    // MARK: - Errors

    public enum DiarizationError: Error, LocalizedError {
        case modelsNotPrepared

        public var errorDescription: String? {
            "Diarization models have not been prepared. Call prepareModels() first."
        }
    }
}
