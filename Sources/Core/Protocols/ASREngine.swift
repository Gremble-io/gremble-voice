import Foundation

/// A speech-to-text engine that can transcribe audio samples.
/// Conforming types must be actors (they hold loaded models).
public protocol ASREngine: Actor, Sendable {
    /// Human-readable engine name (e.g., "Parakeet TDT v3")
    var engineName: String { get }

    /// Whether the model is loaded and ready
    var isModelLoaded: Bool { get }

    /// Download and load the model. Reports progress 0.0→1.0.
    func loadModel(progressHandler: @escaping @Sendable (Double) -> Void) async throws

    /// Unload model to free memory.
    func unloadModel() async

    /// Batch transcribe pre-loaded 16kHz mono Float32 samples.
    func transcribe(samples: [Float]) async throws -> TranscriptionResult

    /// Batch transcribe from a file URL.
    func transcribe(audioURL: URL) async throws -> TranscriptionResult
}

/// Extended protocol for engines that support real-time streaming.
public protocol StreamingASREngine: ASREngine {
    /// Start streaming. Caller feeds audio via addSamples().
    func startStreaming(config: StreamingConfig) async throws

    /// Feed audio samples into the streaming pipeline.
    func addSamples(_ samples: [Float]) async

    /// Async stream of partial transcription results.
    var textUpdates: AsyncStream<StreamingTextUpdate> { get async }

    /// Stop streaming and return final accumulated text.
    func stopStreaming() async throws -> String
}

/// Errors that ASR engine implementations should throw.
public enum ASREngineError: Error, LocalizedError {
    case modelNotLoaded
    case transcriptionFailed(String)
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Model is not loaded"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        }
    }
}
