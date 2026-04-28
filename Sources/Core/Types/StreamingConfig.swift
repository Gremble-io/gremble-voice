import Foundation

/// Configuration for a streaming transcription session.
public struct StreamingConfig: Sendable {
    /// Max samples per transcription pass.
    /// - Dictation preset: 80_000 (5s at 16kHz)
    /// - Meeting preset:   480_000 (30s at 16kHz)
    public let maxBufferSamples: Int

    /// Polling interval in nanoseconds. Set to 0 for VAD-driven mode.
    /// - Dictation preset: 200_000_000 (200ms)
    public let pollingIntervalNs: UInt64

    /// Minimum samples before attempting a transcription pass.
    /// - Dictation preset: 2_400 (150ms at 16kHz)
    /// - Meeting preset:   8_000 (500ms at 16kHz)
    public let minSamples: Int

    public init(maxBufferSamples: Int, pollingIntervalNs: UInt64, minSamples: Int) {
        self.maxBufferSamples = maxBufferSamples
        self.pollingIntervalNs = pollingIntervalNs
        self.minSamples = minSamples
    }

    /// Sliding-window config tuned for low-latency dictation.
    public static let dictation = StreamingConfig(
        maxBufferSamples: 80_000,
        pollingIntervalNs: 200_000_000,
        minSamples: 2_400
    )

    /// VAD-driven config tuned for meeting transcription.
    public static let meeting = StreamingConfig(
        maxBufferSamples: 240_000,
        pollingIntervalNs: 0,
        minSamples: 8_000
    )
}
