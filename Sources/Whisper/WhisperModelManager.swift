import Foundation
import os
import WhisperKit

/// Manages the lifecycle of a WhisperKit model.
///
/// Handles downloading and loading a specific model variant. Both `WhisperEngine`
/// and `WhisperStreamingEngine` hold a reference to a shared `WhisperModelManager`
/// so the model is only loaded once.
public actor WhisperModelManager {

    // MARK: - State

    // nonisolated(unsafe): WhisperKit is a non-Sendable open class.
    // Access is serialised through the WhisperModelManager actor, so this is safe.
    nonisolated(unsafe) private(set) var whisperKit: WhisperKit?
    private(set) var isMultilingual = false
    private var isLoading = false

    private let log = Logger(subsystem: "io.gremble.gremblevoice", category: "WhisperModelManager")

    public init() {}

    // MARK: - Public API

    /// Whether a model is loaded and ready for inference.
    public var isModelLoaded: Bool { whisperKit != nil }

    /// Download (if needed) and load a Whisper model variant.
    ///
    /// - Parameters:
    ///   - variant: WhisperKit model variant string, e.g. `"base.en"`, `"small.en"`,
    ///     `"large-v3"`, `"large-v3-turbo"`. English-only variants end in `.en`.
    ///   - progressHandler: Optional progress callback (0.0 → 1.0). Called on an
    ///     arbitrary thread — dispatch to `@MainActor` if you need to update UI.
    /// - Returns: The local URL of the downloaded model folder.
    @discardableResult
    public func loadModel(
        variant: String,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard !isLoading && whisperKit == nil else {
            throw WhisperModelError.alreadyLoading
        }
        isLoading = true
        defer { isLoading = false }

        log.info("Downloading Whisper model variant: \(variant)")
        progressHandler?(0.02)

        let modelFolder = try await WhisperKit.download(
            variant: variant,
            progressCallback: { progress in
                progressHandler?(progress.fractionCompleted * 0.8 + 0.02)
            }
        )

        log.info("Loading Whisper model from \(modelFolder.path)")
        progressHandler?(0.85)

        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            logLevel: .none,
            prewarm: false,
            load: true,
            download: false
        )
        whisperKit = try await WhisperKit(config)
        isMultilingual = !variant.hasSuffix(".en")

        progressHandler?(1.0)
        log.info("Whisper model loaded (multilingual: \(self.isMultilingual))")
        return modelFolder
    }

    /// Unload the model and free memory.
    public func unloadModel() {
        whisperKit = nil
        isMultilingual = false
        log.info("Whisper model unloaded")
    }

    // MARK: - Errors

    public enum WhisperModelError: Error, LocalizedError {
        case alreadyLoading

        public var errorDescription: String? {
            "A model is already loading. Wait for it to complete before loading another."
        }
    }
}
