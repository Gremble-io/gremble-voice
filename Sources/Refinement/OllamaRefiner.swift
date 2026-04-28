import Foundation
import GrembleVoiceCore
import os

/// Text refinement via a locally-running Ollama server.
///
/// Uses `/api/chat` (Ollama ≥ 0.1.14). Falls back to a plain `TextRefinerError`
/// on network or decoding failure.
public struct OllamaRefiner: TextRefiner {

    // MARK: - Configuration

    /// Default Ollama base URL.
    public static let defaultBaseURL = URL(string: "http://localhost:11434")!
    /// Default model tag.
    public static let defaultModel = "gemma3:4b"

    private let baseURL: URL
    private let model: String
    private let log = Logger(subsystem: "io.gremble.gremblevoice", category: "OllamaRefiner")

    // MARK: - Init

    /// Create an `OllamaRefiner`.
    ///
    /// - Parameters:
    ///   - baseURL: Base URL of the Ollama server. Defaults to `http://localhost:11434`.
    ///   - model: Model tag to use (e.g. `"gemma3:4b"`, `"llama3.2:3b"`).
    public init(
        baseURL: URL = OllamaRefiner.defaultBaseURL,
        model: String = OllamaRefiner.defaultModel
    ) {
        self.baseURL = baseURL
        self.model = model
    }

    // MARK: - TextRefiner

    public func refine(
        text: String,
        context: RefinementContext?,
        customPrompt: String?
    ) async throws -> String {
        let systemPrompt = customPrompt ?? buildSystemPrompt(context: context)

        let body = OllamaChatRequest(
            model: model,
            messages: [
                OllamaMessage(role: "system", content: systemPrompt),
                OllamaMessage(role: "user", content: text),
            ],
            stream: false
        )

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TextRefinerError.networkError("Ollama returned HTTP \(code)")
        }

        let decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
        let refined = decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        log.debug("Ollama refined \(text.count) chars → \(refined.count) chars")
        return refined
    }

    // MARK: - Private helpers

    private func buildSystemPrompt(context: RefinementContext?) -> String {
        var prompt = """
            You are a transcription refinement assistant. Clean up speech-to-text output using these rules:

            1. Remove filler words (um, uh, like, you know, sort of, kind of) and false starts.
            2. Fix grammar, punctuation, and obvious mis-transcribed words.
            3. If the content is clearly a list — action items, to-dos, steps, or enumerated things — \
            format it as a markdown bullet list. Otherwise use plain prose paragraphs.
            4. Only remove pure verbal noise: self-corrections (e.g. "the do — the dev team"), \
            repeated words, and mid-sentence restarts. Do NOT cut intentional content — \
            greetings, sign-offs, questions, and substantive sentences must be kept even if casual.
            5. Preserve the speaker's meaning, tone, voice, and all factual content. Do not \
            rephrase or restructure sentences beyond what is needed to remove noise.
            6. Return only the refined text. No preamble, no explanation, no surrounding quotes.
            """

        if let ctx = context, !ctx.isEmpty {
            prompt += "\n\nContext:"
            if let app = ctx.activeAppName {
                prompt += "\n- Active application: \(app)"
            }
            if let selected = ctx.selectedText {
                prompt += "\n- Selected text: \(selected)"
            }
        }
        return prompt
    }
}

// MARK: - Codable helpers

private struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
}

private struct OllamaMessage: Codable {
    let role: String
    let content: String
}

private struct OllamaChatResponse: Decodable {
    let message: OllamaMessage
}
