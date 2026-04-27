import Foundation
import GrembleVoiceCore
import os

/// Cloud transcription via Groq's Whisper API.
///
/// Groq's endpoint is OpenAI-compatible (`/openai/v1/audio/transcriptions`),
/// so the implementation is structurally identical to `OpenAITranscriber`.
public struct GroqTranscriber: CloudTranscriptionProvider {

    // MARK: - Defaults

    public static let defaultModel = "whisper-large-v3"
    private static let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    // MARK: - Configuration

    private let apiKey: String
    private let model: String
    private let language: String?
    private let log = Logger(subsystem: "io.gremble.gremblevoice", category: "GroqTranscriber")

    // MARK: - Init

    /// Create a `GroqTranscriber`.
    ///
    /// - Parameters:
    ///   - apiKey: Groq API key. Obtain from `https://console.groq.com/`.
    ///   - model: Whisper model variant. Defaults to `"whisper-large-v3"`.
    ///   - language: Optional BCP-47 language hint. `nil` = auto-detect.
    public init(
        apiKey: String,
        model: String = GroqTranscriber.defaultModel,
        language: String? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
    }

    // MARK: - CloudTranscriptionProvider

    public func transcribe(audioURL: URL) async throws -> GrembleVoiceCore.TranscriptionResult {
        let data = try Data(contentsOf: audioURL)
        let ext = audioURL.pathExtension.lowercased().isEmpty
            ? "wav"
            : audioURL.pathExtension.lowercased()
        return try await transcribe(audioData: data, fileExtension: ext)
    }

    public func transcribe(
        audioData: Data,
        fileExtension: String
    ) async throws -> GrembleVoiceCore.TranscriptionResult {
        let start = Date()
        let boundary = "Boundary-\(UUID().uuidString)"
        let mimeType = mimeType(for: fileExtension)

        var body = Data()
        body.appendMultipart(boundary: boundary, name: "model", value: model)
        if let lang = language {
            body.appendMultipart(boundary: boundary, name: "language", value: lang)
        }
        body.appendMultipart(
            boundary: boundary,
            name: "file",
            filename: "audio.\(fileExtension)",
            mimeType: mimeType,
            data: audioData
        )
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: GroqTranscriber.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.requestFailed(-1, "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? "(no body)"
            throw CloudTranscriptionError.requestFailed(http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(WhisperResponse.self, from: responseData)
        let elapsed = Date().timeIntervalSince(start)
        log.debug("Groq Whisper transcribed → \"\(decoded.text.prefix(80))\" (\(String(format: "%.2f", elapsed))s)")

        return GrembleVoiceCore.TranscriptionResult(
            text: decoded.text.trimmingCharacters(in: .whitespacesAndNewlines),
            processingTime: elapsed
        )
    }

    // MARK: - Helpers

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "mp3": return "audio/mpeg"
        case "mp4", "mpeg", "mpga": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "ogg": return "audio/ogg"
        case "webm": return "audio/webm"
        case "flac": return "audio/flac"
        default: return "audio/wav"
        }
    }
}

// MARK: - Response type

private struct WhisperResponse: Decodable {
    let text: String
}
