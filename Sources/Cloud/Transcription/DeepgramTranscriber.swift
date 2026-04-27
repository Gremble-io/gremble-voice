import Foundation
import GrembleVoiceCore
import os

/// Cloud transcription via Deepgram's Nova API.
///
/// Sends raw audio bytes in the request body (no multipart). The `Content-Type`
/// header carries the MIME type. Default model is `nova-3`.
public struct DeepgramTranscriber: CloudTranscriptionProvider {

    // MARK: - Defaults

    public static let defaultModel = "nova-3"
    private static let baseURL = URL(string: "https://api.deepgram.com/v1/listen")!

    // MARK: - Configuration

    private let apiKey: String
    private let model: String
    private let language: String?
    private let log = Logger(subsystem: "io.gremble.gremblevoice", category: "DeepgramTranscriber")

    // MARK: - Init

    /// Create a `DeepgramTranscriber`.
    ///
    /// - Parameters:
    ///   - apiKey: Deepgram API key. Obtain from `https://console.deepgram.com/`.
    ///   - model: Deepgram model. Defaults to `"nova-3"`.
    ///   - language: Optional BCP-47 language code (e.g. `"en-US"`). `nil` = auto-detect.
    public init(
        apiKey: String,
        model: String = DeepgramTranscriber.defaultModel,
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

        var components = URLComponents(url: DeepgramTranscriber.baseURL, resolvingAgainstBaseURL: false)!
        var queryItems = [URLQueryItem(name: "model", value: model)]
        if let lang = language {
            queryItems.append(URLQueryItem(name: "language", value: lang))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(mimeType(for: fileExtension), forHTTPHeaderField: "Content-Type")
        request.httpBody = audioData

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.requestFailed(-1, "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? "(no body)"
            throw CloudTranscriptionError.requestFailed(http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(DeepgramResponse.self, from: responseData)
        guard let transcript = decoded.results.channels.first?
            .alternatives.first?.transcript else {
            throw CloudTranscriptionError.decodingFailed("Empty Deepgram transcript")
        }

        let elapsed = Date().timeIntervalSince(start)
        log.debug("Deepgram transcribed → \"\(transcript.prefix(80))\" (\(String(format: "%.2f", elapsed))s)")

        return GrembleVoiceCore.TranscriptionResult(
            text: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
            processingTime: elapsed
        )
    }

    // MARK: - Helpers

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "mp3": return "audio/mpeg"
        case "mp4", "m4a": return "audio/mp4"
        case "ogg": return "audio/ogg"
        case "webm": return "audio/webm"
        case "flac": return "audio/flac"
        default: return "audio/wav"
        }
    }
}

// MARK: - Response types

private struct DeepgramResponse: Decodable {
    let results: DeepgramResults
}

private struct DeepgramResults: Decodable {
    let channels: [DeepgramChannel]
}

private struct DeepgramChannel: Decodable {
    let alternatives: [DeepgramAlternative]
}

private struct DeepgramAlternative: Decodable {
    let transcript: String
}
