import Foundation

/// A partial result from a streaming transcription pass.
///
/// `confirmedText` is stable across consecutive passes (word-level common prefix).
/// `unconfirmedText` may change as the engine receives more audio.
public struct StreamingTextUpdate: Sendable {
    /// Words that have been stable across at least two consecutive passes.
    public let confirmedText: String
    /// Words still being refined — may change in the next update.
    public let unconfirmedText: String
    /// Per-word timing and confidence from the current pass, if available.
    public let wordTimings: [WordTiming]?

    public init(confirmedText: String, unconfirmedText: String, wordTimings: [WordTiming]? = nil) {
        self.confirmedText = confirmedText
        self.unconfirmedText = unconfirmedText
        self.wordTimings = wordTimings
    }
}
