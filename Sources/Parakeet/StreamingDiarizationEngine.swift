import FluidAudio
import Foundation
import GrembleVoiceCore
import os

/// Real-time streaming speaker diarization backed by FluidAudio's LS-EEND model.
///
/// Runs independently alongside `ParakeetStreamingEngine`. The host app feeds
/// the same audio samples to both and cross-references word timings with
/// speaker segments by timestamp.
///
/// Typical flow:
/// ```swift
/// let diarizer = StreamingDiarizationEngine()
/// try await diarizer.prepareModels { _ in }
/// try await diarizer.startSession()
///
/// // Feed audio from your tap:
/// diarizer.addAudio(samples)
///
/// // Consume speaker updates:
/// for await update in await diarizer.updates {
///     // update.finalizedSegments — stable
///     // update.tentativeSegments — may change
/// }
///
/// let timeline = try await diarizer.stopSession()
/// ```
public actor StreamingDiarizationEngine {

    // MARK: - Configuration

    /// Quality/latency preset controlling timeline post-processing thresholds.
    public enum Preset: Sendable {
        case fast
        case balanced
        case highContext
    }

    // MARK: - Errors

    public enum StreamingDiarizationError: Error, LocalizedError {
        case modelsNotPrepared
        case sessionAlreadyActive
        case sessionNotActive
        case enrollmentFailed(String)

        public var errorDescription: String? {
            switch self {
            case .modelsNotPrepared:
                return "Diarization models have not been prepared. Call prepareModels() first."
            case .sessionAlreadyActive:
                return "A streaming session is already active. Call stopSession() first."
            case .sessionNotActive:
                return "No streaming session is active. Call startSession() first."
            case .enrollmentFailed(let reason):
                return "Speaker enrollment failed: \(reason)"
            }
        }
    }

    // MARK: - Private state

    private let preset: Preset
    private let variant: LSEENDVariant

    // nonisolated(unsafe): LSEENDDiarizer is a non-Sendable final class.
    // Access is serialised through this actor, so this is safe.
    private nonisolated(unsafe) var diarizer: LSEENDDiarizer?

    private var processingTask: Task<Void, Never>?
    private var _updates: AsyncStream<StreamingDiarizationUpdate>?
    private var continuation: AsyncStream<StreamingDiarizationUpdate>.Continuation?
    private var isSessionActive = false

    private var speakerNames: [Int: String] = [:]

    private let log = Logger(subsystem: "io.gremble.gremblevoice", category: "StreamingDiarizationEngine")

    // MARK: - Init

    public init(preset: Preset = .balanced, variant: LSEENDVariant = .dihard3) {
        self.preset = preset
        self.variant = variant
    }

    // MARK: - Public API

    /// Whether models have been downloaded and the diarizer is ready.
    public var isReady: Bool { diarizer?.isAvailable ?? false }

    /// Download (if needed) and prepare the LS-EEND CoreML model.
    public func prepareModels(
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard diarizer == nil else { return }

        log.info("Preparing LS-EEND models (variant: \(String(describing: self.variant)), preset: \(String(describing: self.preset)))")
        progressHandler?(0.05)

        let config = Self.timelineConfigForPreset(preset, numSpeakers: 10)
        let d = LSEENDDiarizer(computeUnits: .cpuOnly, timelineConfig: config)

        try await d.initialize(variant: variant)
        progressHandler?(0.9)

        diarizer = d

        progressHandler?(1.0)
        log.info("LS-EEND ready, speakers=\(d.numSpeakers ?? -1)")
    }

    /// Pre-enroll a known speaker before starting a session.
    ///
    /// Must be called after `prepareModels()` and before `startSession()`.
    ///
    /// - Parameters:
    ///   - name: Display name for this speaker (e.g. "Alice").
    ///   - audioSamples: 16kHz mono Float32 audio of the speaker talking.
    /// - Returns: The enrolled speaker's label with the assigned slot index.
    public func enrollSpeaker(
        name: String,
        audioSamples: [Float]
    ) throws -> SpeakerLabel {
        guard let diarizer else {
            throw StreamingDiarizationError.modelsNotPrepared
        }
        guard !isSessionActive else {
            throw StreamingDiarizationError.sessionAlreadyActive
        }

        let speaker = try diarizer.enrollSpeaker(
            withAudio: audioSamples,
            sourceSampleRate: 16000,
            named: name
        )

        guard let speaker else {
            throw StreamingDiarizationError.enrollmentFailed(
                "Diarizer could not detect speech in the enrollment audio."
            )
        }

        speakerNames[speaker.index] = name
        log.info("Enrolled speaker \"\(name)\" at slot \(speaker.index)")
        return SpeakerLabel(index: speaker.index, name: name)
    }

    /// Start a streaming diarization session.
    public func startSession() async throws {
        guard diarizer != nil else {
            throw StreamingDiarizationError.modelsNotPrepared
        }
        guard !isSessionActive else {
            throw StreamingDiarizationError.sessionAlreadyActive
        }

        let (stream, cont) = AsyncStream<StreamingDiarizationUpdate>.makeStream()
        _updates = stream
        continuation = cont
        isSessionActive = true

        processingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.runProcessCycle()
            }
        }

        log.info("Streaming diarization session started (preset=\(String(describing: self.preset)))")
    }

    /// Feed audio samples into the diarizer.
    ///
    /// Call this from your audio tap at whatever rate samples arrive.
    /// Samples must be 16kHz mono Float32.
    public func addAudio(_ samples: [Float]) {
        guard let diarizer, isSessionActive else { return }
        try? diarizer.addAudio(samples, sourceSampleRate: 16000)
    }

    /// The stream of diarization updates.
    public var updates: AsyncStream<StreamingDiarizationUpdate> {
        get async {
            if let stream = _updates { return stream }
            return AsyncStream { $0.finish() }
        }
    }

    /// Stop the streaming session and return the complete finalized timeline.
    public func stopSession() async throws -> [DiarizedSegment] {
        guard isSessionActive else {
            return []
        }

        if let diarizer {
            _ = try? diarizer.finalizeSession()

            let timeline = diarizer.timeline
            let allSpeakers = timeline.speakers
            var segments: [DiarizedSegment] = []

            for (_, speaker) in allSpeakers {
                for seg in speaker.finalizedSegments {
                    segments.append(convertSegment(seg, isFinalized: true))
                }
            }

            segments.sort { $0.startTime < $1.startTime }

            if !segments.isEmpty {
                continuation?.yield(StreamingDiarizationUpdate(
                    finalizedSegments: segments,
                    tentativeSegments: []
                ))
            }

            await stopSessionInternal()
            log.info("Streaming diarization stopped. \(segments.count) finalized segments.")
            return segments
        }

        await stopSessionInternal()
        return []
    }

    /// Reset the diarizer state for a new session without re-downloading models.
    public func reset() async {
        await stopSessionInternal()
        diarizer?.reset()
        speakerNames.removeAll()
        log.info("Diarization engine reset")
    }

    /// Unload models and free all memory.
    public func unloadModels() async {
        await stopSessionInternal()
        diarizer?.cleanup()
        diarizer = nil
        speakerNames.removeAll()
        log.info("Diarization models unloaded")
    }

    // MARK: - Private

    private func runProcessCycle() {
        guard let diarizer else { return }

        do {
            guard let update = try diarizer.process() else { return }

            let finalized = update.finalizedSegments.map { convertSegment($0, isFinalized: true) }
            let tentative = update.tentativeSegments.map { convertSegment($0, isFinalized: false) }

            guard !finalized.isEmpty || !tentative.isEmpty else { return }

            continuation?.yield(StreamingDiarizationUpdate(
                finalizedSegments: finalized,
                tentativeSegments: tentative
            ))
        } catch {
            log.error("Diarization error: \(error.localizedDescription)")
        }
    }

    private func convertSegment(_ seg: DiarizerSegment, isFinalized: Bool) -> DiarizedSegment {
        let label = SpeakerLabel(
            index: seg.speakerIndex,
            name: speakerNames[seg.speakerIndex]
        )
        return DiarizedSegment(
            speaker: label,
            startTime: TimeInterval(seg.startTime),
            endTime: TimeInterval(seg.endTime),
            confidence: seg.activity,
            isFinalized: isFinalized
        )
    }

    private func stopSessionInternal() async {
        processingTask?.cancel()
        let task = processingTask
        processingTask = nil
        _ = await task?.value

        continuation?.finish()
        continuation = nil
        _updates = nil
        isSessionActive = false
    }

    private static func timelineConfigForPreset(_ preset: Preset, numSpeakers: Int) -> DiarizerTimelineConfig {
        switch preset {
        case .fast:
            return DiarizerTimelineConfig(
                numSpeakers: numSpeakers,
                frameDurationSeconds: 0.1,
                onsetPadFrames: 0,
                maxStoredFrames: 5_000
            )
        case .balanced:
            return DiarizerTimelineConfig(
                numSpeakers: numSpeakers,
                frameDurationSeconds: 0.1,
                onsetPadFrames: 0,
                maxStoredFrames: 11_250
            )
        case .highContext:
            return DiarizerTimelineConfig(
                numSpeakers: numSpeakers,
                frameDurationSeconds: 0.1,
                onsetPadFrames: 0,
                maxStoredFrames: 30_000
            )
        }
    }
}
