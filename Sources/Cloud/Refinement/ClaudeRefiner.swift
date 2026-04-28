import Foundation
import GrembleVoiceCore
import os

/// Text refinement via Anthropic's Claude API.
///
/// The API key is passed at init time — no `UserDefaults` or `NSBundle` reads.
public struct ClaudeRefiner: TextRefiner {

    // MARK: - Defaults

    public static let defaultModel = "claude-3-5-haiku-latest"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    // MARK: - Configuration

    private let apiKey: String
    private let model: String
    private let log = Logger(subsystem: "io.gremble.gremblevoice", category: "ClaudeRefiner")

    // MARK: - Init

    /// Create a `ClaudeRefiner`.
    ///
    /// - Parameters:
    ///   - apiKey: Anthropic API key. Obtain from `https://console.anthropic.com/`.
    ///   - model: Claude model to use. Defaults to `claude-3-5-haiku-latest`.
    public init(
        apiKey: String,
        model: String = ClaudeRefiner.defaultModel
    ) {
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

        let body = ClaudeRequest(
            model: model,
            maxTokens: 1024,
            system: systemPrompt,
            messages: [ClaudeMessage(role: "user", content: text)]
        )

        var request = URLRequest(url: ClaudeRefiner.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(ClaudeRefiner.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TextRefinerError.networkError("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            throw TextRefinerError.networkError("HTTP \(http.statusCode): \(body.prefix(200))")
        }

        let decoded = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        guard let content = decoded.content.first(where: { $0.type == "text" })?.text else {
            throw TextRefinerError.refinementFailed("No text in Claude response")
        }

        let refined = content.trimmingCharacters(in: .whitespacesAndNewlines)
        log.debug("Claude refined \(text.count) chars → \(refined.count) chars")
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

// MARK: - Codable helpers

private struct ClaudeRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [ClaudeMessage]

    enum CodingKeys: String, CodingKey {
        case model, system, messages
        case maxTokens = "max_tokens"
    }
}

private struct ClaudeMessage: Encodable {
    let role: String
    let content: String
}

private struct ClaudeResponse: Decodable {
    let content: [ClaudeContent]
}

private struct ClaudeContent: Decodable {
    let type: String
    let text: String?
}
