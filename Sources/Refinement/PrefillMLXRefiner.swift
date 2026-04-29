import Foundation
import GrembleVoiceCore
import MLX
import MLXLLM
import MLXLMCommon
import os

/// On-device MLX refiner with KV cache pre-warming.
///
/// While the user records (ASR on ANE), this refiner processes the system prompt
/// through the LLM on the GPU, populating the KV cache. When refinement runs,
/// only the transcript tokens need processing, cutting ~600ms off latency.
public actor PrefillMLXRefiner: TextRefiner {

    // MARK: - State

    private let modelID: String
    private var container: ModelContainer?
    private var warmState: WarmCacheState?
    private var prefillPrompt: String?
    private var prefillTask: Task<Void, Error>?
    private let log = Logger(subsystem: "io.gremble.gremblevoice", category: "PrefillMLXRefiner")

    public var isModelLoaded: Bool { container != nil }

    // MARK: - Init

    public init(modelID: String = MLXRefiner.defaultModelID) {
        self.modelID = modelID
    }

    // MARK: - Lifecycle

    public func loadModel(
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard container == nil else { return }
        log.info("Loading MLX model for prefill: \(self.modelID)")

        let downloader = HubApiDownloader()
        let tokenizerLoader = TransformersTokenizerLoader()

        container = try await LLMModelFactory.shared.loadContainer(
            from: downloader,
            using: tokenizerLoader,
            configuration: .init(id: modelID),
            progressHandler: { p in progressHandler?(p.fractionCompleted) }
        )
        log.info("MLX model loaded for prefill")
    }

    public func unloadModel() {
        prefillTask?.cancel()
        prefillTask = nil
        warmState = nil
        prefillPrompt = nil
        container = nil
        log.info("MLX model unloaded")
    }

    // MARK: - Prefill

    /// Pre-warm the KV cache with the system prompt during recording.
    /// Safe to call multiple times; cancels any in-flight prefill.
    public func prefill(systemPrompt: String) async throws {
        guard let container else {
            throw TextRefinerError.modelNotLoaded
        }

        prefillTask?.cancel()
        warmState = nil
        prefillPrompt = systemPrompt

        prefillTask = Task {
            let state = try await container.perform { ctx in
                // Tokenize system-only and system+dummy-user to find the
                // common prefix. Chat templates append a model-turn-start
                // after the last message which diverges when a user turn follows,
                // so we can only safely cache the shared prefix.
                let systemInput = try await ctx.processor.prepare(
                    input: UserInput(chat: [.system(systemPrompt)]))
                let probeInput = try await ctx.processor.prepare(
                    input: UserInput(chat: [.system(systemPrompt), .user("x")]))

                let sysArr: [Int] = systemInput.text.tokens.asArray(Int.self)
                let probeArr: [Int] = probeInput.text.tokens.asArray(Int.self)

                var prefixLen = 0
                while prefixLen < sysArr.count && prefixLen < probeArr.count
                    && sysArr[prefixLen] == probeArr[prefixLen] {
                    prefixLen += 1
                }

                guard prefixLen > 0 else {
                    throw TextRefinerError.refinementFailed("No common prefix between system and combined tokenizations")
                }

                let prefixTokens = systemInput.text.tokens[..<prefixLen]
                let prefixInput = LMInput(tokens: prefixTokens)
                let cache = ctx.model.newCache(parameters: nil)

                _ = ctx.model(
                    prefixInput.text[text: .newAxis],
                    cache: cache.isEmpty ? nil : cache,
                    state: nil)

                eval(cache.flatMap { $0.innerState() })

                return WarmCacheState(cache: cache, prefixTokenCount: prefixLen)
            }

            try Task.checkCancellation()
            self.warmState = state
            self.log.info("Prefill complete: \(state.prefixTokenCount) tokens cached")
        }
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

        if let prefillTask {
            try? await prefillTask.value
        }

        let params = GenerateParameters(maxTokens: 800, temperature: 0.1)

        // For warm cache matching: compare against the base prompt (no context)
        // that was used for prefill. Context is sacrificed in the warm path
        // for latency (it adds ~20 tokens of marginal value for dictation).
        let expectedPrefill = customPrompt ?? Self.defaultSystemPrompt(context: nil)
        let useWarm = warmState != nil && prefillPrompt == expectedPrefill

        do {
            let refined: String
            if useWarm, let warm = warmState, let warmPrompt = prefillPrompt {
                warmState = nil
                refined = try await refineWarm(
                    text: text, systemPrompt: warmPrompt,
                    warm: warm, params: params, container: container)
            } else {
                warmState = nil
                let coldPrompt = customPrompt ?? Self.defaultSystemPrompt(context: context)
                refined = try await refineCold(
                    text: text, systemPrompt: coldPrompt,
                    params: params, container: container)
            }
            let result = refined.trimmingCharacters(in: .whitespacesAndNewlines)
            log.debug("Refined \(text.count) chars -> \(result.count) chars (warm=\(useWarm))")
            return result
        } catch {
            throw TextRefinerError.refinementFailed(error.localizedDescription)
        }
    }

    // MARK: - Private

    /// Warm path: use the pre-warmed KV cache, process only the tokens after the cached prefix.
    private func refineWarm(
        text: String, systemPrompt: String,
        warm: WarmCacheState, params: GenerateParameters,
        container: ModelContainer
    ) async throws -> String {
        try await container.perform(nonSendable: warm) { ctx, warm in
            let fullInput = try await ctx.processor.prepare(
                input: UserInput(chat: [.system(systemPrompt), .user(text)]))
            let fullTokens = fullInput.text.tokens

            let remainingTokens = fullTokens[warm.prefixTokenCount...]
            let remainingInput = LMInput(tokens: remainingTokens)

            let stream = try generate(
                input: remainingInput, cache: warm.cache,
                parameters: params, context: ctx)

            var output = ""
            for await generation in stream {
                if case .chunk(let chunk) = generation {
                    output += chunk
                }
            }
            return output
        }
    }

    /// Cold path: full tokenization, no cache reuse.
    private func refineCold(
        text: String, systemPrompt: String,
        params: GenerateParameters, container: ModelContainer
    ) async throws -> String {
        try await container.perform { ctx in
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
    }

    public static func defaultSystemPrompt(context: RefinementContext?) -> String {
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

// MARK: - Warm cache state

private final class WarmCacheState: @unchecked Sendable {
    let cache: [any KVCache]
    let prefixTokenCount: Int

    init(cache: [any KVCache], prefixTokenCount: Int) {
        self.cache = cache
        self.prefixTokenCount = prefixTokenCount
    }
}
