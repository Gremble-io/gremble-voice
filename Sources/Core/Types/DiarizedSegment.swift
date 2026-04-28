import Foundation

/// A single speaker segment from streaming diarization.
///
/// Maps from FluidAudio's `DiarizerSegment` without requiring a FluidAudio import.
/// Finalized segments are stable; tentative segments may change on the next update.
public struct DiarizedSegment: Sendable {
    /// The speaker who produced this segment.
    public let speaker: SpeakerLabel

    /// Start time in seconds relative to the beginning of the audio stream.
    public let startTime: TimeInterval

    /// End time in seconds.
    public let endTime: TimeInterval

    /// Average speech probability from the diarizer, in [0, 1].
    public let confidence: Float

    /// Whether this segment is confirmed (true) or still tentative (false).
    public let isFinalized: Bool

    /// Duration in seconds.
    public var duration: TimeInterval { endTime - startTime }

    public init(
        speaker: SpeakerLabel,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Float,
        isFinalized: Bool
    ) {
        self.speaker = speaker
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.isFinalized = isFinalized
    }
}
