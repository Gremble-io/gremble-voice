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

    public init(
        text: String,
        language: String? = nil,
        confidence: Float? = nil,
        processingTime: TimeInterval = 0
    ) {
        self.text = text
        self.language = language
        self.confidence = confidence
        self.processingTime = processingTime
    }
}
