import Foundation
import Observation
import OSLog
import GrembleVoiceCore
import GrembleVoiceAudio
import GrembleVoiceParakeet
import GrembleVoiceWhisper
import GrembleVoiceRefinement
import GrembleVoiceCloud

// MARK: - Pipeline

/// The primary entry point for apps using GrembleVoice.
///
/// Usage:
/// ```swift
/// let pipeline = GrembleVoicePipeline(config: myConfig)
/// try await pipeline.loadModel { progress in ... }
/// try await pipeline.startRecording()
/// // ... user speaks ...
/// var session = try await pipeline.stopRecording()
/// session.injectedText = textInjector.lastInjectedText
/// sessionStore.save(session)
/// ```
@Observable @MainActor
public final class GrembleVoicePipeline {

    // MARK: - Observable state

    /// True while the mic is open and ASR is receiving samples.
    public private(set) var isRecording = false

    /// RMS audio level of the most recent mic chunk, 0.0–1.0 (linear, not dBFS).
    public private(set) var audioLevel: Float = 0

    /// True once the ASR model is loaded and ready.
    public private(set) var isModelLoaded = false

    /// 0.0→1.0 download/load progress for the current model. Reset to 0 after load.
    public private(set) var modelLoadProgress: Double = 0

    /// The most recently completed session. Set at the end of stopRecording().
    public private(set) var lastSession: GrembleSession?

    // MARK: - Configuration

    /// Mutable — apps can update this between sessions (e.g. user changes refiner in Settings).
    public var config: PipelineConfig

    // MARK: - Private state

    private var parakeetEngine: ParakeetStreamingEngine?
    private var whisperEngine: WhisperStreamingEngine?
    private var micSource: MicCaptureSource?
    private var feedTask: Task<Void, Never>?
    private var recordingStart: Date?
    private let dictionaryProcessor = DictionaryProcessor()
    private var prefillRefiner: PrefillMLXRefiner?

    // MARK: - Init

    public init(config: PipelineConfig) {
        self.config = config
    }

    // MARK: - Model Loading

    /// Download and load the ASR model configured in `config.asrEngine`.
    /// Safe to call multiple times — no-ops if already loaded with the same engine.
    public func loadModel(
        progressHandler: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        isModelLoaded = false
        modelLoadProgress = 0

        let throttle = ProgressThrottle()
        let wrappedProgress: @Sendable (Double) -> Void = { [weak self] p in
            guard throttle.shouldReport(p) else { return }
            Task { @MainActor [weak self] in
                self?.modelLoadProgress = p
                progressHandler(p)
            }
        }

        switch config.asrEngine {
        case .parakeet:
            PipelineLogger.asr.info("Loading Parakeet v3 model")
            let engine = parakeetEngine ?? ParakeetStreamingEngine()
            try await engine.loadModel(progressHandler: wrappedProgress)
            parakeetEngine = engine

        case .whisper(let variant):
            PipelineLogger.asr.info("Loading Whisper variant: \(variant)")
            let engine = whisperEngine ?? WhisperStreamingEngine(variant: variant)
            try await engine.loadModel(progressHandler: wrappedProgress)
            whisperEngine = engine
        }

        if case .mlx(let modelID, _) = config.refiner {
            let refiner = prefillRefiner ?? PrefillMLXRefiner(modelID: modelID)
            try await refiner.loadModel(progressHandler: wrappedProgress)
            self.prefillRefiner = refiner
        } else if prefillRefiner != nil {
            await prefillRefiner?.unloadModel()
            prefillRefiner = nil
        }

        isModelLoaded = true
        modelLoadProgress = 1.0
        PipelineLogger.asr.info("Model loaded: \(self.config.asrEngine.displayName)")
    }

    /// Unload the current ASR model to free memory.
    public func unloadModel() async {
        await parakeetEngine?.unloadModel()
        await whisperEngine?.unloadModel()
        await prefillRefiner?.unloadModel()
        prefillRefiner = nil
        isModelLoaded = false
        PipelineLogger.asr.info("Model unloaded")
    }

    // MARK: - Recording

    /// Start mic capture and begin feeding samples into the ASR streaming engine.
    /// Throws if no model is loaded, or if mic permissions are denied.
    public func startRecording() async throws {
        guard !isRecording else { return }
        guard isModelLoaded else {
            PipelineLogger.asr.error("startRecording() called but model not loaded")
            throw PipelineError.modelNotLoaded
        }

        let mic = MicCaptureSource()
        micSource = mic
        let stream = try await mic.start()

        // Pick the active ASR engine
        guard let asrEngine = activeStreamingEngine() else {
            throw PipelineError.modelNotLoaded
        }

        // Start streaming on the ASR engine
        try await asrEngine.startStreaming(config: streamingConfig())

        isRecording = true
        recordingStart = Date()
        audioLevel = 0

        PipelineLogger.audio.info(
            "Recording started — engine: \(self.config.asrEngine.displayName)"
        )

        // Trigger prefill on the GPU while ASR runs on the ANE
        if let prefillRefiner, case .mlx(_, let customPrompt) = config.refiner {
            let prompt = customPrompt ?? PrefillMLXRefiner.defaultSystemPrompt(context: nil)
            Task { try? await prefillRefiner.prefill(systemPrompt: prompt) }
        }

        // Single consumer task: feeds samples to ASR + updates audio level meter
        feedTask = Task { [weak self] in
            for await samples in stream {
                guard let self, !Task.isCancelled else { break }
                await asrEngine.addSamples(samples)
                let level = AudioLevelMeter.rms(samples)
                await MainActor.run { self.audioLevel = level }
            }
        }
    }

    /// Stop recording and run the full post-processing pipeline.
    /// Returns a `GrembleSession` with all fields populated (except `injectedText`,
    /// which the caller sets after TextInjector runs).
    public func stopRecording() async throws -> GrembleSession {
        guard isRecording else { throw PipelineError.notRecording }

        isRecording = false
        audioLevel = 0

        // Stop mic and sample feed
        feedTask?.cancel()
        feedTask = nil
        await micSource?.stop()
        micSource = nil

        let duration = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        recordingStart = nil

        guard let asrEngine = activeStreamingEngine() else {
            throw PipelineError.modelNotLoaded
        }

        // Capture app context synchronously before anything else
        let context = ContextCapture.captureSync(
            enabled: true,
            userBlocklist: []
        )

        let log = EventLog()
        let startTimestamp = Date()
        log.record(
            stage: .recordingStarted,
            message: "duration=\(String(format: "%.1f", duration))s engine=\(config.asrEngine.displayName) app=\(context.activeAppName ?? "unknown")"
        )
        PipelineLogger.asr.info(
            "Recording stopped — \(String(format: "%.1f", duration))s, app: \(context.activeAppName ?? "unknown")"
        )

        // Brief pause so the final 200ms polling pass captures the last spoken words
        try? await Task.sleep(for: .milliseconds(150))

        // ── Stage 1: ASR ──────────────────────────────────────────────────────
        let asrStart = Date()
        var rawText: String
        let rawAsrOutput: String  // true ASR output, pre-ArtifactStripper
        do {
            rawText = try await asrEngine.stopStreaming()
            rawAsrOutput = rawText  // capture BEFORE stripping — used as training input
            rawText = ArtifactStripper.strip(rawText)
        } catch {
            let msg = "ASR failed: \(error.localizedDescription)"
            log.record(stage: .error, message: msg, error: error.localizedDescription)
            PipelineLogger.asr.error("\(msg)")
            throw PipelineError.asrFailed(error)
        }

        let asrMs = Int(Date().timeIntervalSince(asrStart) * 1000)
        let wordCount = rawText.split(separator: " ").count
        log.record(
            stage: .asrComplete,
            message: "words=\(wordCount) duration=\(asrMs)ms text=\"\(String(rawText.prefix(60)))\""
        )
        PipelineLogger.asr.info(
            "ASR complete — \(wordCount) words in \(asrMs)ms: \"\(String(rawText.prefix(60)))\""
        )

        // ── Stage 2: Dictionary ───────────────────────────────────────────────
        let dictStart = Date()
        let enabledEntries = config.dictionaryEntries.filter { $0.isEnabled }
        let dictText: String
        var dictSubstitutions = 0

        if enabledEntries.isEmpty {
            dictText = rawText
        } else {
            let before = rawText
            dictText = dictionaryProcessor.process(
                rawText,
                using: enabledEntries,
                language: config.language
            )
            // Count changed words as a rough substitution metric
            let beforeWords = before.split(separator: " ")
            let afterWords = dictText.split(separator: " ")
            dictSubstitutions = zip(beforeWords, afterWords).filter { $0 != $1 }.count
                + abs(afterWords.count - beforeWords.count)
        }

        let dictMs = Int(Date().timeIntervalSince(dictStart) * 1000)
        log.record(
            stage: .dictComplete,
            message: "entries=\(enabledEntries.count) substitutions=\(dictSubstitutions) duration=\(dictMs)ms"
        )
        PipelineLogger.dict.info(
            "Dictionary — \(enabledEntries.count) entries, \(dictSubstitutions) substitutions in \(dictMs)ms"
        )

        // ── Stage 3: Refinement ───────────────────────────────────────────────
        let refinedText: String
        let refinerName = config.refiner.displayName
        var isRefinementFallback = false
        var fallbackReason: String? = nil

        if case .none = config.refiner {
            refinedText = dictText
            PipelineLogger.llm.info("Refinement skipped (mode: none)")
        } else if dictText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            refinedText = dictText
            PipelineLogger.llm.info("Refinement skipped (empty input)")
        } else {
            log.record(
                stage: .refineStarted,
                message: "refiner=\(refinerName) chars=\(dictText.count)"
            )
            PipelineLogger.llm.info(
                "Refine start — refiner=\(refinerName), input=\(dictText.count) chars"
            )

            let refineStart = Date()
            do {
                let refiner = try makeRefiner()

                // Strip credentials before sending to cloud refiners
                let inputText = config.refiner.isCloud
                    ? SensitiveDataFilter.filter(dictText).sanitizedText
                    : dictText

                let customPrompt: String?
                if case .ollama(_, _, let prompt) = config.refiner { customPrompt = prompt }
                else if case .mlx(_, let prompt) = config.refiner { customPrompt = prompt }
                else { customPrompt = nil }

                let rawResult = try await refiner.refine(
                    text: inputText,
                    context: context,
                    customPrompt: customPrompt
                )

                let stripped = PreambleStripper.strip(rawResult)
                let refineMs = Int(Date().timeIntervalSince(refineStart) * 1000)

                // Validate result
                let validation = RefinementValidator.validate(
                    result: stripped,
                    original: dictText,
                    isStructuredContext: isStructuredContext(context)
                )

                switch validation {
                case .accept:
                    refinedText = stripped.isEmpty ? dictText : stripped
                    log.record(
                        stage: .refineComplete,
                        message: "refiner=\(refinerName) duration=\(refineMs)ms validation=accept chars_out=\(refinedText.count)"
                    )
                    PipelineLogger.llm.info(
                        "Refine complete — \(refineMs)ms, accepted, \(refinedText.count) chars out"
                    )

                case .fallback(let reason):
                    refinedText = dictText
                    isRefinementFallback = true
                    fallbackReason = reason
                    log.record(
                        stage: .refineFallback,
                        message: "refiner=\(refinerName) duration=\(refineMs)ms reason=\(reason)"
                    )
                    PipelineLogger.llm.warning(
                        "Refine fallback — \(reason) (kept dict-processed text)"
                    )
                }
            } catch {
                refinedText = dictText
                isRefinementFallback = true
                fallbackReason = "refiner_error"
                let msg = "Refine error: \(error.localizedDescription)"
                log.record(stage: .error, message: msg, error: error.localizedDescription)
                PipelineLogger.llm.error("\(msg) — falling back to dict-processed text")
            }
        }

        // ── Build session ─────────────────────────────────────────────────────
        let session = GrembleSession(
            startedAt: startTimestamp,
            recordingDuration: duration,
            activeApp: context.activeAppName,
            activeBundleID: context.activeAppBundleID,
            asrEngine: config.asrEngine.displayName,
            refiner: refinerName,
            rawAsrOutput: rawAsrOutput,
            rawTranscript: rawText,
            dictionaryProcessed: dictText,
            refinedText: refinedText,
            events: log.finish(),
            isRefinementFallback: isRefinementFallback,
            fallbackReason: fallbackReason
        )

        lastSession = session

        PipelineLogger.session.info(
            "Session complete — id=\(session.id) raw=\(rawText.count)chars refined=\(refinedText.count)chars"
        )

        return session
    }

    // MARK: - Two-phase recording (inject-first, refine-later)

    /// Inputs needed to run refinement after the fast path returns.
    /// Captured during stopRecordingFast() so context is correct even if user switches apps.
    public struct RefinementInput: Sendable {
        public let dictText: String
        public let context: RefinementContext
        public let refinerName: String
        public let config: PipelineConfig
        public let prefillRefiner: PrefillMLXRefiner?
    }

    /// Result of background refinement.
    public struct RefinementResult: Sendable {
        public let refinedText: String
        public let isRefinementFallback: Bool
        public let fallbackReason: String?
        public let events: [PipelineEvent]
    }

    /// Stop recording and run ASR + dictionary only. Returns immediately — no refinement.
    /// Use `runRefinement(_:)` afterward for async background refinement.
    ///
    /// The returned session has `refinedText == dictionaryProcessed` as a placeholder.
    /// Also returns a `RefinementInput` for passing to `runRefinement()`.
    public func stopRecordingFast() async throws -> (session: GrembleSession, refinementInput: RefinementInput?) {
        guard isRecording else { throw PipelineError.notRecording }

        isRecording = false
        audioLevel = 0

        feedTask?.cancel()
        feedTask = nil
        await micSource?.stop()
        micSource = nil

        let duration = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        recordingStart = nil

        guard let asrEngine = activeStreamingEngine() else {
            throw PipelineError.modelNotLoaded
        }

        // Capture context NOW — before user switches apps
        let context = ContextCapture.captureSync(enabled: true, userBlocklist: [])

        let log = EventLog()
        let startTimestamp = Date()
        log.record(
            stage: .recordingStarted,
            message: "duration=\(String(format: "%.1f", duration))s engine=\(config.asrEngine.displayName) app=\(context.activeAppName ?? "unknown")"
        )

        // Brief pause for final polling pass
        try? await Task.sleep(for: .milliseconds(150))

        // ── Stage 1: ASR ──
        let asrStart = Date()
        var rawText: String
        let rawAsrOutput: String
        do {
            rawText = try await asrEngine.stopStreaming()
            rawAsrOutput = rawText
            rawText = ArtifactStripper.strip(rawText)
        } catch {
            log.record(stage: .error, message: "ASR failed: \(error.localizedDescription)", error: error.localizedDescription)
            throw PipelineError.asrFailed(error)
        }

        let asrMs = Int(Date().timeIntervalSince(asrStart) * 1000)
        log.record(stage: .asrComplete, message: "words=\(rawText.split(separator: " ").count) duration=\(asrMs)ms")

        // ── Stage 2: Dictionary ──
        let enabledEntries = config.dictionaryEntries.filter { $0.isEnabled }
        let dictText: String
        if enabledEntries.isEmpty {
            dictText = rawText
        } else {
            dictText = dictionaryProcessor.process(rawText, using: enabledEntries, language: config.language)
        }
        log.record(stage: .dictComplete, message: "entries=\(enabledEntries.count)")

        let refinerName = config.refiner.displayName

        // Build session with refinedText = dictText (placeholder)
        let session = GrembleSession(
            startedAt: startTimestamp,
            recordingDuration: duration,
            activeApp: context.activeAppName,
            activeBundleID: context.activeAppBundleID,
            asrEngine: config.asrEngine.displayName,
            refiner: refinerName,
            rawAsrOutput: rawAsrOutput,
            rawTranscript: rawText,
            dictionaryProcessed: dictText,
            refinedText: dictText,  // placeholder — will be updated after refinement
            events: log.finish(),
            isRefinementFallback: false,
            fallbackReason: nil
        )

        lastSession = session

        // Prepare refinement input if refinement is enabled
        let refinementInput: RefinementInput?
        if case .none = config.refiner {
            refinementInput = nil
        } else if dictText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            refinementInput = nil
        } else {
            refinementInput = RefinementInput(
                dictText: dictText,
                context: context,
                refinerName: refinerName,
                config: config,
                prefillRefiner: self.prefillRefiner
            )
        }

        PipelineLogger.session.info(
            "Fast path complete — id=\(session.id) dictText=\(dictText.count)chars refinement=\(refinementInput != nil ? "pending" : "none")"
        )

        return (session, refinementInput)
    }

    /// Run refinement in the background. Safe to call from a detached Task.
    /// This method is nonisolated — it doesn't touch @MainActor state.
    nonisolated public func runRefinement(_ input: RefinementInput) async -> RefinementResult {
        let log = EventLog()

        if input.dictText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log.record(stage: .refineComplete, message: "skipped (empty input)")
            return RefinementResult(
                refinedText: input.dictText,
                isRefinementFallback: false,
                fallbackReason: nil,
                events: log.finish()
            )
        }

        log.record(stage: .refineStarted, message: "refiner=\(input.refinerName) chars=\(input.dictText.count)")

        let refineStart = Date()
        do {
            let refiner: any TextRefiner
            if let prefill = input.prefillRefiner {
                refiner = prefill
            } else {
                refiner = try makeRefinerFromConfig(input.config)
            }

            let inputText = input.config.refiner.isCloud
                ? SensitiveDataFilter.filter(input.dictText).sanitizedText
                : input.dictText

            let customPrompt: String?
            if case .ollama(_, _, let prompt) = input.config.refiner { customPrompt = prompt }
            else if case .mlx(_, let prompt) = input.config.refiner { customPrompt = prompt }
            else { customPrompt = nil }

            let rawResult = try await refiner.refine(
                text: inputText,
                context: input.context,
                customPrompt: customPrompt
            )

            let stripped = PreambleStripper.strip(rawResult)
            let refineMs = Int(Date().timeIntervalSince(refineStart) * 1000)

            let isStructured: Bool = {
                guard let id = input.context.activeAppBundleID?.lowercased(),
                      let name = input.context.activeAppName?.lowercased() else { return false }
                return ContextAwarePromptBuilder.isNotes(id: id, name: name)
                    || ContextAwarePromptBuilder.isCode(id: id, name: name)
            }()

            let validation = RefinementValidator.validate(
                result: stripped,
                original: input.dictText,
                isStructuredContext: isStructured
            )

            switch validation {
            case .accept:
                let refinedText = stripped.isEmpty ? input.dictText : stripped
                log.record(stage: .refineComplete, message: "duration=\(refineMs)ms validation=accept")
                return RefinementResult(
                    refinedText: refinedText,
                    isRefinementFallback: false,
                    fallbackReason: nil,
                    events: log.finish()
                )
            case .fallback(let reason):
                log.record(stage: .refineFallback, message: "duration=\(refineMs)ms reason=\(reason)")
                return RefinementResult(
                    refinedText: input.dictText,
                    isRefinementFallback: true,
                    fallbackReason: reason,
                    events: log.finish()
                )
            }
        } catch {
            log.record(stage: .error, message: "Refine error: \(error.localizedDescription)", error: error.localizedDescription)
            return RefinementResult(
                refinedText: input.dictText,
                isRefinementFallback: true,
                fallbackReason: "refiner_error",
                events: log.finish()
            )
        }
    }

    /// Creates a refiner from config — nonisolated version for background use.
    nonisolated private func makeRefinerFromConfig(_ config: PipelineConfig) throws -> any TextRefiner {
        switch config.refiner {
        case .none:
            throw PipelineError.noRefiner
        case .ollama(let baseURL, let model, _):
            let url = URL(string: baseURL) ?? OllamaRefiner.defaultBaseURL
            return OllamaRefiner(baseURL: url, model: model)
        case .mlx(let modelID, _):
            return MLXRefiner(modelID: modelID)
        case .claude(let apiKey, let model):
            return ClaudeRefiner(apiKey: apiKey, model: model)
        case .openai(let apiKey, let model):
            return OpenAIRefiner(apiKey: apiKey, model: model)
        case .groq(let apiKey, let model):
            return GroqRefiner(apiKey: apiKey, model: model)
        }
    }

    // MARK: - Private helpers

    private func activeStreamingEngine() -> (any StreamingASREngine)? {
        switch config.asrEngine {
        case .parakeet: return parakeetEngine
        case .whisper:  return whisperEngine
        }
    }

    private func streamingConfig() -> StreamingConfig {
        // Dictation preset: 5s window, 200ms poll
        .dictation
    }

    private func makeRefiner() throws -> any TextRefiner {
        switch config.refiner {
        case .none:
            throw PipelineError.noRefiner

        case .ollama(let baseURL, let model, _):
            let url = URL(string: baseURL) ?? OllamaRefiner.defaultBaseURL
            return OllamaRefiner(baseURL: url, model: model)

        case .mlx(let modelID, _):
            if let prefillRefiner { return prefillRefiner }
            return MLXRefiner(modelID: modelID)

        case .claude(let apiKey, let model):
            return ClaudeRefiner(apiKey: apiKey, model: model)

        case .openai(let apiKey, let model):
            return OpenAIRefiner(apiKey: apiKey, model: model)

        case .groq(let apiKey, let model):
            return GroqRefiner(apiKey: apiKey, model: model)
        }
    }

    private func isStructuredContext(_ context: RefinementContext) -> Bool {
        guard let bundleID = context.activeAppBundleID,
              let appName = context.activeAppName else { return false }
        let id = bundleID.lowercased()
        let name = appName.lowercased()
        return ContextAwarePromptBuilder.isNotes(id: id, name: name)
            || ContextAwarePromptBuilder.isCode(id: id, name: name)
    }
}

// MARK: - Errors

private final class ProgressThrottle: @unchecked Sendable {
    private var last: Double = 0
    func shouldReport(_ p: Double) -> Bool {
        if p < last { last = 0 }
        if p >= 1.0 || p - last >= 0.01 {
            last = p
            return true
        }
        return false
    }
}

public enum PipelineError: Error, LocalizedError {
    case modelNotLoaded
    case notRecording
    case asrFailed(Error)
    case noRefiner

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:      return "ASR model is not loaded."
        case .notRecording:        return "stopRecording() called but pipeline is not recording."
        case .asrFailed(let e):    return "ASR failed: \(e.localizedDescription)"
        case .noRefiner:           return "No refiner configured."
        }
    }
}
