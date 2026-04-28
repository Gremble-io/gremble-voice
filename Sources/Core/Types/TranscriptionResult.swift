import Foundation

/// The result of a batch transcription pass.
public struct TranscriptionResult: Sendable {
    /// The transcribed text, with artifacts already stripped.
    public let text: String
    /// BCP-47 language code detected by the engine, if available.
    public let language: String?
    /// Confidence score in [0, 1], if available.
    public let confidence: Float?
    /// Wall-clock time taken to transcribe, in seconds.
    public let processingTime: TimeInterval
    /// Per-word timing and confidence, if the engine provides it.
    public let wordTimings: [WordTiming]?

    public init(
        text: String,
        language: String? = nil,
        confidence: Float? = nil,
        processingTime: TimeInterval = 0,
        wordTimings: [WordTiming]? = nil
    ) {
        self.text = text
        self.language = language
        self.confidence = confidence
        self.processingTime = processingTime
        self.wordTimings = wordTimings
    }
}

/// Timing and confidence for a single word or subword token.
public struct WordTiming: Sendable {
    public let word: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let confidence: Float

    public init(word: String, startTime: TimeInterval, endTime: TimeInterval, confidence: Float) {
        self.word = word
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}
