@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import GrembleVoiceCore
import os

/// Captures live microphone audio and yields 16kHz mono Float32 sample chunks.
///
/// Conforms to `AudioSource` — feed the returned `AsyncStream` directly into
/// any `ASREngine` or `StreamingASREngine`.
///
/// Mic permission must be granted before calling `start()`. On macOS add
/// `NSMicrophoneUsageDescription` to your app's Info.plist and request access
/// via `AVCaptureDevice.requestAccess(for: .audio)` before the first call.
///
/// Example:
/// ```swift
/// let mic = MicCaptureSource()
/// let stream = try await mic.start()
/// for await samples in stream {
///     await engine.addSamples(samples)
/// }
/// ```
public actor MicCaptureSource: AudioSource {

    // MARK: - Public

    public nonisolated let sourceName: String
    public private(set) var isCapturing = false

    // MARK: - Private

    private let deviceID: AudioDeviceID?
    private let engine = AVAudioEngine()
    /// Converter is set once in `start()` and only accessed from AVAudioEngine's
    /// audio render thread — `nonisolated(unsafe)` is intentional here.
    nonisolated(unsafe) private var converter: AVAudioConverter?
    private let log = Logger(subsystem: "io.gremble.gremblevoice", category: "MicCaptureSource")

    // MARK: - Init

    /// - Parameter deviceID: CoreAudio device ID to capture from.
    ///   Pass `nil` to use the system-default input device.
    ///   Use `AudioDeviceManager.availableInputDevices()` to enumerate choices.
    public init(deviceID: AudioDeviceID? = nil) {
        self.deviceID = deviceID
        if let id = deviceID, let name = AudioDeviceManager.deviceName(for: id) {
            self.sourceName = name
        } else {
            self.sourceName = "Default Microphone"
        }
    }

    // MARK: - AudioSource

    public func start() async throws -> AsyncStream<[Float]> {
        guard !isCapturing else {
            throw AudioSourceError.captureFailure("Already capturing")
        }

        // Route to a specific device if requested.
        if let id = deviceID {
            let audioUnit = engine.inputNode.audioUnit!
            var devID = id
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw AudioSourceError.deviceUnavailable(
                    "Failed to set input device (OSStatus \(status))")
            }
        }

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw AudioSourceError.deviceUnavailable(
                "Invalid hardware format: sr=\(hwFormat.sampleRate) ch=\(hwFormat.channelCount)")
        }

        guard let conv = AVAudioConverter(from: hwFormat, to: AudioResampler.targetFormat) else {
            throw AudioSourceError.captureFailure("Could not create audio converter")
        }
        converter = conv

        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        // Capture converter locally so the tap closure doesn't reference actor state.
        let capturedConverter = conv
        let targetFormat = AudioResampler.targetFormat
        let hwSampleRate = hwFormat.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { buffer, _ in
            // AVAudioPCMBuffer is not Sendable — extract [Float] here on the audio thread.
            let outputFrameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * AudioResampler.targetSampleRate / hwSampleRate
            ) + 1

            guard let outBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: max(outputFrameCount, 1)
            ) else { return }

            // Single-buffer input block — flag prevents the converter from asking twice.
            final class _Flag: @unchecked Sendable { var done = false }
            let flag = _Flag()
            var convError: NSError?
            capturedConverter.convert(to: outBuffer, error: &convError) { _, status in
                if flag.done { status.pointee = .noDataNow; return nil }
                flag.done = true
                status.pointee = .haveData
                return buffer
            }

            guard convError == nil, outBuffer.frameLength > 0,
                  let channelData = outBuffer.floatChannelData else { return }

            let samples = Array(UnsafeBufferPointer(
                start: channelData[0],
                count: Int(outBuffer.frameLength)
            ))
            continuation.yield(samples)
        }

        do {
            engine.prepare()
            try engine.start()
            isCapturing = true
            log.info("MicCaptureSource started: \(self.sourceName), hw \(hwFormat.sampleRate)Hz → 16kHz")
        } catch {
            inputNode.removeTap(onBus: 0)
            converter = nil
            throw AudioSourceError.captureFailure(error.localizedDescription)
        }

        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }

        return stream
    }

    public func stop() async {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        converter = nil
        isCapturing = false
        log.info("MicCaptureSource stopped")
    }
}
