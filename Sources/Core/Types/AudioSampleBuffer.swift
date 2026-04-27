import Foundation

/// Thread-safe accumulator for 16kHz mono Float32 audio samples.
///
/// Used by streaming engines to collect samples between transcription passes.
/// The actor model ensures concurrent `append` and `consume` calls are safe.
public actor AudioSampleBuffer {
    private var buffer: [Float] = []

    public init() {}

    /// Append new samples to the buffer.
    public func append(_ samples: [Float]) {
        buffer.append(contentsOf: samples)
    }

    /// Current number of samples in the buffer.
    public var count: Int { buffer.count }

    /// Copy the current buffer contents without clearing.
    public func peek() -> [Float] { buffer }

    /// Copy and clear the buffer, returning all accumulated samples.
    public func consume() -> [Float] {
        defer { buffer.removeAll(keepingCapacity: true) }
        return buffer
    }

    /// Trim the oldest samples to keep the buffer at most `maxSamples` long.
    public func trim(to maxSamples: Int) {
        guard buffer.count > maxSamples else { return }
        buffer.removeFirst(buffer.count - maxSamples)
    }
}
