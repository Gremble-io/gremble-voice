import Foundation
import GrembleVoiceCore

// MARK: - Pipeline Config

/// Everything `GrembleVoicePipeline` needs to know about how to run.
/// The host app constructs this from its own state and passes it in.
/// Mutable so the host app can update it between sessions (e.g. user changes refiner in Settings).
public struct PipelineConfig: Sendable {

    /// Which ASR engine to use for transcription.
    public var asrEngine: ASREngineChoice

    /// Which refinement backend to use (or none).
    public var refiner: RefinerChoice

    /// Active dictionary entries to apply after transcription.
    public var dictionaryEntries: [DictionaryEntry]

    /// BCP-47 language code used for dictionary matching, e.g. "en", "fr".
    public var language: String

    public init(
        asrEngine: ASREngineChoice = .parakeet,
        refiner: RefinerChoice = .none,
        dictionaryEntries: [DictionaryEntry] = [],
        language: String = "en"
    ) {
        self.asrEngine = asrEngine
        self.refiner = refiner
        self.dictionaryEntries = dictionaryEntries
        self.language = language
    }
}

// MARK: - ASR Engine Choice

public extension PipelineConfig {

    enum ASREngineChoice: Sendable {
        /// FluidAudio Parakeet TDT v3 — 25 languages, best English accuracy, Apple Neural Engine optimized.
        case parakeet
        /// WhisperKit — specify model variant string, e.g. "base.en", "large-v3".
        case whisper(variant: String)

        /// Human-readable name logged to sessions and shown in the Debug Log.
        public var displayName: String {
            switch self {
            case .parakeet:             return "Parakeet v3"
            case .whisper(let variant): return "Whisper \(variant)"
            }
        }
    }
}

// MARK: - Refiner Choice

public extension PipelineConfig {

    enum RefinerChoice: Sendable {
        /// No refinement — raw ASR output (after dict processing) is injected as-is.
        case none
        /// Local Ollama server. Defaults: http://localhost:11434, gemma3:4b.
        case ollama(baseURL: String = "http://localhost:11434",
                    model: String = "gemma3:4b",
                    customPrompt: String? = nil)
        /// On-device MLX LLM. Default: Gemma 3 4B instruction-tuned, 4-bit quantized.
        case mlx(modelID: String = "mlx-community/gemma-3-4b-it-4bit",
                 customPrompt: String? = nil)
        /// Anthropic Claude API (BYOK).
        case claude(apiKey: String, model: String = "claude-3-5-haiku-latest")
        /// OpenAI Chat Completions API (BYOK).
        case openai(apiKey: String, model: String = "gpt-4o-mini")
        /// Groq Chat API — OpenAI-compatible (BYOK).
        case groq(apiKey: String, model: String = "llama-3.1-70b-versatile")

        /// Human-readable name logged to sessions.
        public var displayName: String {
            switch self {
            case .none:                     return "none"
            case .ollama(_, let model, _):  return "Ollama \(model)"
            case .mlx(let id, _):
                // Use the last path component of the HuggingFace model ID.
                return "MLX \(id.split(separator: "/").last.map(String.init) ?? id)"
            case .claude(_, let model):     return "Claude \(model)"
            case .openai(_, let model):     return "OpenAI \(model)"
            case .groq(_, let model):       return "Groq \(model)"
            }
        }

        /// Whether this refiner sends data off-device (triggers sensitive data filtering).
        public var isCloud: Bool {
            switch self {
            case .claude, .openai, .groq: return true
            default:                      return false
            }
        }
    }
}
