import Foundation
import GrembleVoiceCore

/// A cloud-hosted speech-to-text backend.
///
/// All providers accept a local audio file URL. Where possible they also accept
/// raw audio data (avoiding a second disk read for in-memory buffers).
///
/// Thread-safe: conforming types must be `Sendable`.
public protocol CloudTranscriptionProvider: Sendable {

    /// Transcribe the audio file at `audioURL`.
    ///
    /// The provider handles upload encoding internally.
    func transcribe(audioURL: URL) async throws -> GrembleVoiceCore.TranscriptionResult

    /// Transcribe raw audio bytes.
    ///
    /// - Parameters:
    ///   - audioData: Raw audio file bytes (e.g. a WAV or M4A in memory).
    ///   - fileExtension: File extension used to hint the MIME type (e.g. `"wav"`, `"m4a"`).
    func transcribe(
        audioData: Data,
        fileExtension: String
    ) async throws -> GrembleVoiceCore.TranscriptionResult
}

/// Errors specific to cloud transcription.
public enum CloudTranscriptionError: Error, LocalizedError {
    case requestFailed(Int, String)
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .requestFailed(let code, let body):
            return "Cloud transcription failed (HTTP \(code)): \(body.prefix(200))"
        case .decodingFailed(let detail):
            return "Failed to decode transcription response: \(detail)"
        }
    }
}
