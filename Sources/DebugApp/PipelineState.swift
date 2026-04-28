import Accelerate
import Foundation
import GrembleVoiceAudio
import GrembleVoiceCloud
import GrembleVoiceCore
import GrembleVoiceParakeet
import GrembleVoiceRefinement
import GrembleVoiceWhisper

// MARK: - Supporting enums

enum ASRChoice: String, CaseIterable, Identifiable {
    case parakeet = "Parakeet"
    case whisper = "Whisper"
    var id: String { rawValue }
}

enum RefinerChoice: String, CaseIterable, Identifiable {
    case none = "None"
    case ollama = "Ollama"
    case mlx = "MLX"
    case claude = "Claude"
    case openAI = "OpenAI"
    case groq = "Groq"
    var id: String { rawValue }
}

enum LoadStatus {
    case unloaded
    case loading(Double)   // 0.0 – 1.0
    case loaded
    case failed(String)

    var isLoaded: Bool { if case .loaded = self { return true }; return false }
    var isLoading: Bool { if case .loading = self { return true }; return false }
    var progress: Double? { if case .loading(let p) = self { return p }; return nil }
    var errorMessage: String? { if case .failed(let m) = self { return m }; return nil }
}

// MARK: - PipelineState

/// Central state object — owns all engines and drives recording/refinement.
///
/// All mutations happen on `@MainActor`. Engine calls cross actor boundaries
/// via `Task { }` blocks, bridging results back to the main actor.
@Observable
@MainActor
final class PipelineState {

    // MARK: - Ollama setup state
    var ollamaServerRunning = false
    var ollamaModelReady = false
    var isPullingModel = false
    var ollamaPullProgress: Double = 0
    var ollamaPullStatus = ""
    var ollamaPullError: String?
    var showOllamaSetup = false

    private let ollamaManager = OllamaManager()

    // MARK: - Selection
    var selectedASR: ASRChoice = .parakeet
    var selectedRefiner: RefinerChoice = .ollama  // Ollama is the default

    // MARK: - Model status
    var parakeetStatus: LoadStatus = .unloaded
    var whisperStatus: LoadStatus = .unloaded
    var mlxStatus: LoadStatus = .unloaded

    // MARK: - Recording state
    var isRecording = false
    var audioLevel: Float = 0

    // MARK: - Dictionary
    let dictionary = DictionaryStore()
    private let dictionaryProcessor = DictionaryProcessor()

    // MARK: - Text output
    var rawFinalText = ""           // straight from ASR
    var dictionaryText = ""         // after DictionaryProcessor
    var refinedText = ""            // after LLM refiner
    var isRefining = false
    var errorMessage: String?

    // MARK: - Config
    var ollamaBaseURL = "http://localhost:11434"
    var ollamaModel = "gemma3:4b"
    var claudeAPIKey = ""
    var openAIAPIKey = ""
    var groqAPIKey = ""
    var mlxModelID = MLXRefiner.defaultModelID
    var whisperVariant = "base.en"

    // MARK: - Engines

    // Shared model manager so ParakeetEngine and ParakeetStreamingEngine load once.
    let parakeetModelManager = ParakeetModelManager()
    private var _parakeetEngine: ParakeetStreamingEngine?
    private var _whisperEngine: WhisperStreamingEngine?
    private var _mlxRefiner: MLXRefiner?

    private var parakeetEngine: ParakeetStreamingEngine {
        if let e = _parakeetEngine { return e }
        let e = ParakeetStreamingEngine(modelManager: parakeetModelManager)
        _parakeetEngine = e
        return e
    }

    // MARK: - Active recording tasks
    private var audioTask: Task<Void, Never>?
    private var activeMic: MicCaptureSource?

    // MARK: - Ollama setup

    func checkOllamaStatus() {
        Task {
            let status = await ollamaManager.checkStatus()
            switch status {
            case .notRunning:
                ollamaServerRunning = false
                ollamaModelReady = false
                showOllamaSetup = true
            case .running(let models):
                ollamaServerRunning = true
                let modelName = OllamaManager.defaultModel
                ollamaModelReady = models.contains { $0.hasPrefix(modelName.components(separatedBy: ":").first ?? modelName) }
                showOllamaSetup = !ollamaModelReady
            }
        }
    }

    func pullOllamaModel() {
        Task {
            isPullingModel = true
            ollamaPullProgress = 0
            ollamaPullStatus = "Starting…"
            ollamaPullError = nil
            do {
                try await ollamaManager.pullModel(OllamaManager.defaultModel) { [weak self] fraction, status in
                    Task { @MainActor [weak self] in
                        self?.ollamaPullProgress = fraction
                        self?.ollamaPullStatus = status
                        if status == "success" {
                            self?.ollamaModelReady = true
                            self?.isPullingModel = false
                        }
                    }
                }
                ollamaModelReady = true
            } catch {
                ollamaPullError = error.localizedDescription
            }
            isPullingModel = false
        }
    }

    // MARK: - Model loading

    func loadParakeet() {
        Task {
            parakeetStatus = .loading(0)
            errorMessage = nil
            do {
                try await parakeetEngine.loadModel { [weak self] p in
                    Task { @MainActor [weak self] in
                        self?.parakeetStatus = .loading(p)
                    }
                }
                parakeetStatus = .loaded
            } catch {
                parakeetStatus = .failed(error.localizedDescription)
            }
        }
    }

    func unloadParakeet() {
        guard !isRecording else { return }
        Task {
            await parakeetEngine.unloadModel()
            parakeetStatus = .unloaded
        }
    }

    func loadWhisper() {
        let variant = whisperVariant
        Task {
            whisperStatus = .loading(0)
            errorMessage = nil
            let engine = WhisperStreamingEngine(variant: variant)
            do {
                try await engine.loadModel { [weak self] p in
                    Task { @MainActor [weak self] in
                        self?.whisperStatus = .loading(p)
                    }
                }
                _whisperEngine = engine
                whisperStatus = .loaded
            } catch {
                whisperStatus = .failed(error.localizedDescription)
            }
        }
    }

    func unloadWhisper() {
        guard !isRecording else { return }
        Task {
            await _whisperEngine?.unloadModel()
            _whisperEngine = nil
            whisperStatus = .unloaded
        }
    }

    func loadMLX() {
        let modelID = mlxModelID
        Task {
            mlxStatus = .loading(0)
            errorMessage = nil
            let refiner = MLXRefiner(modelID: modelID)
            do {
                try await refiner.loadModel { [weak self] p in
                    Task { @MainActor [weak self] in
                        self?.mlxStatus = .loading(p)
                    }
                }
                _mlxRefiner = refiner
                mlxStatus = .loaded
            } catch {
                mlxStatus = .failed(error.localizedDescription)
            }
        }
    }

    func unloadMLX() {
        Task {
            await _mlxRefiner?.unloadModel()
            _mlxRefiner = nil
            mlxStatus = .unloaded
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording, !isRefining else { return }
        rawFinalText = ""
        dictionaryText = ""
        refinedText = ""
        errorMessage = nil

        Task {
            // Choose streaming engine
            let engine: any StreamingASREngine
            switch selectedASR {
            case .parakeet:
                guard await parakeetEngine.isModelLoaded else {
                    errorMessage = "Load Parakeet first (Models tab)."
                    return
                }
                engine = parakeetEngine
            case .whisper:
                guard let we = _whisperEngine, await we.isModelLoaded else {
                    errorMessage = "Load Whisper first (Models tab)."
                    return
                }
                engine = we
            }

            let mic = MicCaptureSource()
            do {
                let audioStream = try await mic.start()
                try await engine.startStreaming(config: .dictation)
                activeMic = mic
                isRecording = true

                // Feed audio into engine + drive the level meter
                audioTask = Task { [weak self] in
                    for await samples in audioStream {
                        await engine.addSamples(samples)
                        var rms: Float = 0
                        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
                        let level = min(rms * 20, 1.0)
                        await MainActor.run { self?.audioLevel = level }
                    }
                    await MainActor.run { self?.audioLevel = 0 }
                }
            } catch {
                errorMessage = "Mic error: \(error.localizedDescription)"
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false

        // Cancel immediately — don't wait for the async Task to schedule
        audioTask?.cancel()
        audioTask = nil

        let mic = activeMic
        activeMic = nil
        let asrChoice = selectedASR
        let refinerChoice = selectedRefiner

        Task {
            await mic?.stop()

            // Final pass: transcribe the full accumulated buffer
            let finalText: String
            switch asrChoice {
            case .parakeet:
                finalText = (try? await parakeetEngine.stopStreaming()) ?? ""
            case .whisper:
                finalText = (try? await _whisperEngine?.stopStreaming()) ?? ""
            }

            rawFinalText = finalText

            // Apply dictionary substitutions before sending to the LLM
            let entries = dictionary.entries
            let processor = dictionaryProcessor
            let dictProcessed = entries.isEmpty
                ? finalText
                : processor.process(finalText, using: entries, language: "en")
            dictionaryText = dictProcessed

            guard refinerChoice != .none, !dictProcessed.isEmpty else { return }
            isRefining = true
            do {
                let refiner = buildRefiner(refinerChoice)
                refinedText = try await refiner.refine(text: dictProcessed, context: nil, customPrompt: nil)
            } catch {
                refinedText = "Refinement failed: \(error.localizedDescription)"
            }
            isRefining = false
        }
    }

    // MARK: - Private

    private func buildRefiner(_ choice: RefinerChoice) -> any TextRefiner {
        switch choice {
        case .none:    return IdentityRefiner()
        case .ollama:  return OllamaRefiner(
                           baseURL: URL(string: ollamaBaseURL) ?? OllamaRefiner.defaultBaseURL,
                           model: ollamaModel)
        case .mlx:     return _mlxRefiner ?? IdentityRefiner()
        case .claude:  return ClaudeRefiner(apiKey: claudeAPIKey)
        case .openAI:  return OpenAIRefiner(apiKey: openAIAPIKey)
        case .groq:    return GroqRefiner(apiKey: groqAPIKey)
        }
    }
}

// MARK: - IdentityRefiner

private struct IdentityRefiner: TextRefiner {
    func refine(text: String, context: RefinementContext?, customPrompt: String?) async throws -> String { text }
}
