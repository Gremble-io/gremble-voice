import Foundation
import GrembleVoiceCore

/// An `AudioSource` that replays an audio file as a stream of 16kHz mono Float32 chunks.
///
/// Useful for integration tests and offline debugging — pipe any WAV/m4a/mp3 file
/// through the same ASR pipeline as live mic input without needing to speak.
///
/// The file is resampled via `AudioResampler` then yielded in fixed-size chunks.
/// Chunks are delivered without artificial delay, so playback is faster than real-time.
///
/// Example:
/// ```swift
/// let source = AudioFileSource(url: Bundle.main.url(forResource: "test", withExtension: "wav")!)
/// let stream = try await source.start()
/// for await samples in stream {
///     await engine.addSamples(samples)
/// }
/// ```
public actor AudioFileSource: AudioSource {

    // MARK: - Public

    public nonisolated let sourceName: String
    public private(set) var isCapturing = false

    // MARK: - Private

    private let url: URL
    private let chunkSize: Int

    // MARK: - Init

    /// - Parameters:
    ///   - url: Path to any audio file readable by `AVAudioFile` (WAV, m4a, AIFF, etc.)
    ///   - chunkSize: Samples per chunk. Default is 4096 (~256ms at 16kHz), matching
    ///     the buffer size used by `MicCaptureSource`.
    public init(url: URL, chunkSize: Int = 4096) {
        self.url = url
        self.sourceName = url.lastPathComponent
        self.chunkSize = chunkSize
    }

    // MARK: - AudioSource

    public func start() async throws -> AsyncStream<[Float]> {
        guard !isCapturing else {
            throw AudioSourceError.captureFailure("Already capturing")
        }

        let samples: [Float]
        do {
            samples = try AudioResampler.resampleFile(at: url)
        } catch {
            throw AudioSourceError.captureFailure(
                "Could not load audio file '\(url.lastPathComponent)': \(error.localizedDescription)")
        }

        isCapturing = true
        let size = chunkSize

        let (stream, continuation) = AsyncStream<[Float]>.makeStream()

        Task {
            var offset = 0
            while offset < samples.count {
                let end = min(offset + size, samples.count)
                continuation.yield(Array(samples[offset..<end]))
                offset = end
            }
            continuation.finish()
        }

        return stream
    }

    public func stop() async {
        isCapturing = false
    }
}
