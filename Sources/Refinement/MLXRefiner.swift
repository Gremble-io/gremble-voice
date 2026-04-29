import Foundation
import GrembleVoiceCore
import MLXLLM
import MLXLMCommon
import os

/// On-device LLM text refinement backed by MLX.
///
/// Downloads (once) and loads a quantised model from the HuggingFace Hub, then
/// uses it to clean up ASR output via a system + user prompt pair.
///
/// Example:
/// ```swift
/// let refiner = MLXRefiner()
/// try await refiner.loadModel { p in print("Loading: \(Int(p * 100))%") }
/// let clean = try await refiner.refine(text: rawASR, context: ctx, customPrompt: nil)
/// ```
public actor MLXRefiner: TextRefiner {

    // MARK: - Configuration

    /// Default model — Gemma 3 4B instruction-tuned, 4-bit quantised.
    public static let defaultModelID = "mlx-community/gemma-3-4b-it-4bit"

    // MARK: - State

    private let modelID: String
    private var container: ModelContainer?
    private let log = Logger(subsystem: "io.gremble.gremblevoice", category: "MLXRefiner")

    /// Whether the model is loaded and ready for inference.
    public var isModelLoaded: Bool { container != nil }

    // MARK: - Init

    public init(modelID: String = MLXRefiner.defaultModelID) {
        self.modelID = modelID
    }

    // MARK: - Lifecycle

    /// Download (if needed) and load the MLX model.
    ///
    /// - Parameter progressHandler: Called on an arbitrary thread with values 0.0 → 1.0.
    ///   Dispatch to `@MainActor` if you need to update UI.
    public func loadModel(
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard container == nil else { return }
        log.info("Loading MLX model: \(self.modelID)")

        let downloader = HubApiDownloader()
        let tokenizerLoader = TransformersTokenizerLoader()

        container = try await LLMModelFactory.shared.loadContainer(
            from: downloader,
            using: tokenizerLoader,
            configuration: .init(id: modelID),
            progressHandler: { p in progressHandler?(p.fractionCompleted) }
        )
        log.info("MLX model loaded")
    }

    /// Unload the model and free GPU/ANE memory.
    public func unloadModel() {
        container = nil
        log.info("MLX model unloaded")
    }

    // MARK: - TextRefiner

    public func refine(
        text: String,
        context: RefinementContext?,
        customPrompt: String?
    ) async throws -> String {
        guard let container else {
            throw TextRefinerError.modelNotLoaded
        }

        let systemPrompt = customPrompt ?? buildSystemPrompt(context: context)
        let params = GenerateParameters(maxTokens: 800, temperature: 0.1)

        do {
            let refined = try await container.perform { ctx in
                let messages: [Chat.Message] = [
                    .system(systemPrompt),
                    .user(text),
                ]
                let lmInput = try await ctx.processor.prepare(
                    input: UserInput(chat: messages))
                let stream = try generate(
                    input: lmInput, parameters: params, context: ctx)
                var output = ""
                for await generation in stream {
                    if case .chunk(let chunk) = generation {
                        output += chunk
                    }
                }
                return output
            }
            let result = refined.trimmingCharacters(in: .whitespacesAndNewlines)
            log.debug("Refined \(text.count) chars → \(result.count) chars")
            return result
        } catch {
            throw TextRefinerError.refinementFailed(error.localizedDescription)
        }
    }

    // MARK: - Private helpers

    private func buildSystemPrompt(context: RefinementContext?) -> String {
        var prompt = """
            You are a transcription refinement assistant. Clean up speech-to-text output by \
            correcting grammar, punctuation, and obvious mis-heard words, while preserving the \
            speaker's meaning and tone. Return only the refined text with no preamble or explanation.
            """

        if let ctx = context, !ctx.isEmpty {
            prompt += "\n\nContext:"
            if let app = ctx.activeAppName {
                prompt += "\n- Active application: \(app)"
            }
            if let selected = ctx.selectedText {
                prompt += "\n- Selected text (for formatting cues): \(selected)"
            }
            if let url = ctx.browserURL {
                prompt += "\n- Browser URL: \(url)"
            }
        }
        return prompt
    }
}
