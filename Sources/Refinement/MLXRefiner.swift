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

    public static let defaultModelID = "mlx-community/Llama-3.2-3B-Instruct-4bit"

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

        do {
            let refined = try await container.perform { ctx in
                let messages: [Chat.Message] = [
                    .system(systemPrompt),
                    .user(text),
                ]
                let lmInput = try await ctx.processor.prepare(
                    input: UserInput(chat: messages))

                let vocabProcessor = InputVocabularyProcessor.build(
                    transcript: text, tokenizer: ctx.tokenizer)
                let transcriptTokenCount = ctx.tokenizer.encode(
                    text: text, addSpecialTokens: false).count
                let maxTokens = max(transcriptTokenCount + 30,
                                    Int(Double(transcriptTokenCount) * 1.3))

                let iterator = try TokenIterator(
                    input: lmInput, model: ctx.model,
                    processor: vocabProcessor, sampler: ArgMaxSampler(),
                    maxTokens: maxTokens)

                let (stream, _) = generateTask(
                    promptTokenCount: lmInput.text.tokens.size,
                    modelConfiguration: ctx.configuration,
                    tokenizer: ctx.tokenizer,
                    iterator: iterator)

                var output = ""
                for await generation in stream {
                    if case .chunk(let chunk) = generation { output += chunk }
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
        PrefillMLXRefiner.defaultSystemPrompt(context: context)
    }
}
