import Foundation

/// A text refinement backend (local LLM, cloud API, or Ollama).
public protocol TextRefiner: Sendable {
    /// Refine raw ASR output into clean text.
    /// - Parameters:
    ///   - text: Raw transcription to clean up
    ///   - context: Optional app context for formatting
    ///   - customPrompt: Optional user-provided system prompt override
    func refine(
        text: String,
        context: RefinementContext?,
        customPrompt: String?
    ) async throws -> String
}

/// Errors that refinement backends should throw.
public enum TextRefinerError: Error, LocalizedError {
    case modelNotLoaded
    case refinementFailed(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Refinement model is not loaded"
        case .refinementFailed(let reason):
            return "Refinement failed: \(reason)"
        case .networkError(let reason):
            return "Network error: \(reason)"
        }
    }
}
