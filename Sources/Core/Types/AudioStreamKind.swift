import Foundation

/// Identifies which audio stream produced a set of samples.
///
/// ASR engines that maintain per-stream decoder state (e.g., Parakeet via FluidAudio)
/// use this to keep microphone and system audio transcription separate.
public enum AudioStreamKind: String, Sendable {
    case microphone
    case system
}
