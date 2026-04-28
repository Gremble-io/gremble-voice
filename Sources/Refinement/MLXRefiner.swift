import Foundation
import GrembleVoiceCore
import Hub
import MLXLLM
import MLXLMCommon
import os
import Tokenizers

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

// MARK: - Downloader bridge (Hub → MLXLMCommon.Downloader)

/// Wraps `HubApi` from `swift-transformers` as an `MLXLMCommon.Downloader`.
///
/// `swift-transformers` is already in the dependency graph via WhisperKit, so
/// no extra package is required.
private struct HubApiDownloader: MLXLMCommon.Downloader {

    private let api: HubApi

    init(token: String? = nil) {
        api = token.map { HubApi(hfToken: $0) } ?? HubApi.shared
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try await api.snapshot(
            from: id,
            revision: revision ?? "main",
            matching: patterns.isEmpty ? ["*"] : patterns,
            progressHandler: progressHandler
        )
    }
}

// MARK: - TokenizerLoader bridge (Tokenizers → MLXLMCommon.TokenizerLoader)

/// Wraps `AutoTokenizer` from `swift-transformers` as an `MLXLMCommon.TokenizerLoader`.
private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {

    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TransformersTokenizerBridge(upstream)
    }
}

/// Bridges `Tokenizers.Tokenizer` (swift-transformers) to `MLXLMCommon.Tokenizer`.
private struct TransformersTokenizerBridge: MLXLMCommon.Tokenizer, @unchecked Sendable {

    // Tokenizers.Tokenizer implementations are @unchecked Sendable; we inherit that.
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers uses `decode(tokens:)` instead of `decode(tokenIds:)`.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
