import Foundation
import GrembleVoiceCore
import os

/// Text refinement via Groq's OpenAI-compatible Chat Completions API.
///
/// Groq's endpoint is a drop-in compatible with OpenAI's `/v1/chat/completions`,
/// making this structurally identical to `OpenAIRefiner` with a different base URL
/// and default model.
public struct GroqRefiner: TextRefiner {

    // MARK: - Defaults

    public static let defaultModel = "llama-3.1-70b-versatile"
    private static let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    // MARK: - Configuration

    private let apiKey: String
    private let model: String
    private let log = Logger(subsystem: "io.gremble.gremblevoice", category: "GroqRefiner")

    // MARK: - Init

    /// Create a `GroqRefiner`.
    ///
    /// - Parameters:
    ///   - apiKey: Groq API key. Obtain from `https://console.groq.com/`.
    ///   - model: Model to use. Defaults to `llama-3.1-70b-versatile`.
    public init(apiKey: String, model: String = GroqRefiner.defaultModel) {
        self.apiKey = apiKey
        self.model = model
    }

    // MARK: - TextRefiner

    public func refine(
        text: String,
        context: RefinementContext?,
        customPrompt: String?
    ) async throws -> String {
        let systemPrompt = customPrompt ?? buildSystemPrompt(context: context)

        let body = ChatCompletionRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: text),
            ],
            maxTokens: 1024,
            temperature: 0.1
        )

        var request = URLRequest(url: GroqRefiner.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TextRefinerError.networkError("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            throw TextRefinerError.networkError("HTTP \(http.statusCode): \(body.prefix(200))")
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw TextRefinerError.refinementFailed("No content in Groq response")
        }

        let refined = content.trimmingCharacters(in: .whitespacesAndNewlines)
        log.debug("Groq refined \(text.count) chars → \(refined.count) chars")
        return refined
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
            if let app = ctx.activeAppName { prompt += "\n- Active application: \(app)" }
            if let selected = ctx.selectedText { prompt += "\n- Selected text: \(selected)" }
            if let url = ctx.browserURL { prompt += "\n- Browser URL: \(url)" }
            if let clipboard = ctx.clipboardText { prompt += "\n- Clipboard: \(clipboard)" }
        }
        return prompt
    }
}
