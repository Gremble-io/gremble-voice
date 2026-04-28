import FluidAudio
import Foundation
import os

/// Manages the lifecycle of FluidAudio ASR and VAD models.
///
/// This actor is the single source of truth for whether models are downloaded and loaded.
/// Both `ParakeetEngine` and `ParakeetStreamingEngine` hold a reference to a shared
/// `ParakeetModelManager` so model memory is only allocated once.
public actor ParakeetModelManager {

    // MARK: - State

    private(set) var asrManager: AsrManager?
    private(set) var isLoading = false

    private let log = Logger(subsystem: "io.gremble.gremblevoice", category: "ParakeetModelManager")

    public init() {}

    // MARK: - Public API

    /// Whether the ASR model is downloaded, loaded, and ready for inference.
    public var isModelLoaded: Bool { asrManager != nil }

    /// Download (if needed) and load the Parakeet ASR model.
    ///
    /// Progress is reported 0.0 → 1.0 via `progressHandler`. The handler may be called
    /// from any thread — dispatch to the main actor if you need to update UI.
    ///
    /// - Parameters:
    ///   - version: Model version to load (default `.v3` — multilingual, 600 MB).
    ///   - progressHandler: Optional download/load progress callback.
    public func loadModel(
        version: AsrModelVersion = .v3,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard !isLoading && asrManager == nil else { return }
        isLoading = true
        defer { isLoading = false }

        log.info("Loading Parakeet models (version: \(String(describing: version)))")
        progressHandler?(0.05)

        let models = try await AsrModels.downloadAndLoad(
            version: version,
            progressHandler: { progress in progressHandler?(progress.fractionCompleted * 0.85 + 0.05) }
        )

        progressHandler?(0.9)

        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)

        asrManager = manager
        progressHandler?(1.0)
        log.info("Parakeet models loaded and ready")
    }

    /// Unload models and free memory.
    public func unloadModel() async {
        await asrManager?.cleanup()
        asrManager = nil
        log.info("Parakeet models unloaded")
    }

    /// Create a fresh `VadManager` for speech activity detection.
    ///
    /// Each caller (mic, system audio) should have its own VAD state.
    ///
    /// - Parameter threshold: VAD speech/non-speech threshold (0–1, default 0.85).
    public func makeVadManager(threshold: Float = 0.85) async throws -> VadManager {
        try await VadManager(config: VadConfig(defaultThreshold: threshold))
    }
}
