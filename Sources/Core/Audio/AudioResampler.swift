import Foundation
@preconcurrency import AVFoundation

/// Converts audio from any format to 16kHz mono Float32 — the format required
/// by all GrembleVoice ASR backends.
public enum AudioResampler {

    /// Target sample rate for all ASR engines.
    public static let targetSampleRate: Double = 16_000

    /// Target output format: 16kHz mono Float32.
    public static var targetFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    // MARK: - Errors

    public enum ResamplerError: Error, LocalizedError {
        case unsupportedSourceFormat
        case converterInitFailed
        case conversionFailed(String)
        case fileReadFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedSourceFormat:
                return "Source audio format is not supported"
            case .converterInitFailed:
                return "Failed to initialize audio converter"
            case .conversionFailed(let reason):
                return "Audio conversion failed: \(reason)"
            case .fileReadFailed(let reason):
                return "Failed to read audio file: \(reason)"
            }
        }
    }

    // MARK: - Public API

    /// Load an audio file and resample it to 16kHz mono Float32.
    ///
    /// - Parameter url: Path to any audio file readable by `AVAudioFile`.
    /// - Returns: `[Float]` samples at 16kHz mono.
    public static func resampleFile(at url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw ResamplerError.converterInitFailed
        }

        let frameCount = AVAudioFrameCount(
            Double(file.length) * targetSampleRate / file.processingFormat.sampleRate
        )
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
            throw ResamplerError.conversionFailed("Could not allocate output buffer")
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            let capacity = AVAudioFrameCount(file.processingFormat.sampleRate * 0.5)
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: capacity
            ) else {
                outStatus.pointee = .noDataNow
                return nil
            }
            do {
                try file.read(into: inputBuffer)
                outStatus.pointee = inputBuffer.frameLength > 0 ? .haveData : .endOfStream
                return inputBuffer
            } catch {
                outStatus.pointee = .endOfStream
                return nil
            }
        }

        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error {
            throw ResamplerError.conversionFailed(error.localizedDescription)
        }
        if status == .error {
            throw ResamplerError.conversionFailed("Conversion returned error status")
        }

        guard let channelData = outputBuffer.floatChannelData else {
            throw ResamplerError.conversionFailed("No channel data in output buffer")
        }

        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }

    /// Resample an `AVAudioPCMBuffer` to 16kHz mono Float32.
    ///
    /// The buffer must already have a known processing format.
    public static func resample(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            throw ResamplerError.converterInitFailed
        }

        let outputFrameCount = AVAudioFrameCount(
            Double(buffer.frameLength) * targetSampleRate / buffer.format.sampleRate
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: max(outputFrameCount, 1)
        ) else {
            throw ResamplerError.conversionFailed("Could not allocate output buffer")
        }

        final class _Flag: @unchecked Sendable { var value = false }
        let consumed = _Flag()
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed.value {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed.value = true
            outStatus.pointee = .haveData
            return buffer
        }

        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error {
            throw ResamplerError.conversionFailed(error.localizedDescription)
        }
        if status == .error {
            throw ResamplerError.conversionFailed("Conversion returned error status")
        }

        guard let channelData = outputBuffer.floatChannelData else {
            throw ResamplerError.conversionFailed("No channel data in output buffer")
        }

        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }
}
