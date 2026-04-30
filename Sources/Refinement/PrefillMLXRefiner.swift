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

        let params = GenerateParameters(maxTokens: 800, temperature: 0.1, repetitionPenalty: 1.2, repetitionContextSize: 64)

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
            You are a transcript formatter. Your job is to add punctuation and \
            capitalization to raw speech-to-text output. You may also make these \
            specific edits:

            1. Remove filled pauses: um, uh, er, hmm
            2. Collapse stuttered repetitions: "the the" becomes "the"
            3. When the speaker corrects themselves, remove the abandoned part \
            and keep the correction: "I want to, no, I need to" becomes "I need to"
            4. Remove filler "like" only when it has no grammatical role: \
            "we need to like update" becomes "we need to update"

            Rules:
            - Your output must use ONLY words the speaker said. Never add, \
            substitute, or rephrase.
            - Keep all discourse markers: honestly, actually, basically, really, \
            pretty, wow, oh, yeah, well, okay, so
            - Keep the speaker's tone and style. Casual speech stays casual.
            - Output the formatted text only. No explanations, labels, or commentary.

            Examples:
            Input: "um so I want to no actually I need to lets go with the second approach for the API"
            Output: "I need to, let's go with the second approach for the API."

            Input: "the the thing is we need to like update the cache invalidation logic because its uh its breaking on deploy"
            Output: "The thing is, we need to update the cache invalidation logic because it's breaking on deploy."

            Input: "honestly though it works pretty well I didnt expect it to be this fast"
            Output: "Honestly though, it works pretty well. I didn't expect it to be this fast."

            Input: "wow thats actually really cool I cant believe it handled that"
            Output: "Wow, that's actually really cool. I can't believe it handled that."
            WRONG: "That's impressive. I can't believe it handled that."
            This is wrong because it rephrased the speaker's words and dropped "wow".
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
