import Foundation

/// A source of 16kHz mono Float32 audio samples.
/// Implementations handle mic capture, system audio, or file-based input.
public protocol AudioSource: Actor, Sendable {
    /// Human-readable description (e.g., "Built-in Microphone")
    var sourceName: String { get }

    /// Whether the source is currently capturing audio
    var isCapturing: Bool { get }

    /// Start capturing and yield [Float] sample chunks via the returned stream.
    /// Samples must be 16kHz mono Float32.
    func start() async throws -> AsyncStream<[Float]>

    /// Stop capturing audio.
    func stop() async
}

/// Errors that audio source implementations should throw.
public enum AudioSourceError: Error, LocalizedError {
    case permissionDenied
    case deviceUnavailable(String)
    case captureFailure(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone permission denied"
        case .deviceUnavailable(let device):
            return "Audio device unavailable: \(device)"
        case .captureFailure(let reason):
            return "Audio capture failed: \(reason)"
        }
    }
}
