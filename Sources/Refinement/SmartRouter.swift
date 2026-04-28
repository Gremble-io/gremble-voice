import Foundation
import GrembleVoiceCore

/// Configuration for `SmartRouter`.
///
/// Specifies the primary refinement backend and an optional fallback for when
/// the primary throws. All fields are set at init time — no `UserDefaults`.
public struct SmartRouterConfig: Sendable {

    /// The available backend choices for text refinement.
    public enum Backend: Sendable {
        /// On-device MLX model (default: Gemma 3 4B 4-bit).
        case mlx(modelID: String = MLXRefiner.defaultModelID)
        /// Local Ollama server.
        case ollama(baseURL: URL = OllamaRefiner.defaultBaseURL, model: String = OllamaRefiner.defaultModel)
        /// Any `TextRefiner` (e.g. `ClaudeRefiner`, `OpenAIRefiner`).
        case custom(any TextRefiner)
    }

    /// Primary backend to try first.
    public let primary: Backend
    /// Fallback backend if `primary` throws. `nil` means let the error propagate.
    public let fallback: (any TextRefiner)?

    public init(primary: Backend, fallback: (any TextRefiner)? = nil) {
        self.primary = primary
        self.fallback = fallback
    }
}

/// Routes refinement calls to the configured backend, with optional fallback.
///
/// `SmartRouter` is an actor so that on-device model state (loading, container)
/// can be safely accessed from any async context.
public actor SmartRouter: TextRefiner {

    private let primary: any TextRefiner
    private let fallback: (any TextRefiner)?

    // MARK: - Init

    /// Create a `SmartRouter` from a `SmartRouterConfig`.
    ///
    /// If `config.primary` is `.mlx` or `.ollama`, the refiner is instantiated here.
    /// If it is `.custom`, the provided refiner is used as-is.
    public init(config: SmartRouterConfig) {
        switch config.primary {
        case .mlx(let modelID):
            primary = MLXRefiner(modelID: modelID)
        case .ollama(let baseURL, let model):
            primary = OllamaRefiner(baseURL: baseURL, model: model)
        case .custom(let refiner):
            primary = refiner
        }
        self.fallback = config.fallback
    }

    // MARK: - Lifecycle helpers

    /// Load the primary refiner's model (no-op for network refiners).
    public func loadModel(progressHandler: (@Sendable (Double) -> Void)? = nil) async throws {
        if let mlx = primary as? MLXRefiner {
            try await mlx.loadModel(progressHandler: progressHandler)
        }
    }

    /// Unload the primary refiner's model (no-op for network refiners).
    public func unloadModel() async {
        if let mlx = primary as? MLXRefiner {
            await mlx.unloadModel()
        }
    }

    // MARK: - TextRefiner

    public func refine(
        text: String,
        context: RefinementContext?,
        customPrompt: String?
    ) async throws -> String {
        do {
            return try await primary.refine(
                text: text, context: context, customPrompt: customPrompt)
        } catch {
            guard let fallback else { throw error }
            return try await fallback.refine(
                text: text, context: context, customPrompt: customPrompt)
        }
    }
}
