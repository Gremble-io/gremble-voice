import Foundation
import os

/// Manages the local Ollama installation: checks availability, lists models,
/// and pulls new models with streaming progress.
///
/// Use this during onboarding to verify that Ollama is running and the
/// required model is available before presenting the main UI.
///
/// Example:
/// ```swift
/// let manager = OllamaManager()
/// let status = await manager.checkStatus()
///
/// if case .running(let models) = status, !models.contains("gemma3:4b") {
///     try await manager.pullModel("gemma3:4b") { progress, status in
///         print("\(Int(progress * 100))% – \(status)")
///     }
/// }
/// ```
public actor OllamaManager {

    // MARK: - Types

    /// The result of a status check.
    public enum Status: Sendable {
        /// Could not reach the Ollama server (not installed or not running).
        case notRunning
        /// Server is reachable. `models` is the list of pulled model names.
        case running(models: [String])
    }

    public enum OllamaError: Error, LocalizedError {
        case serverNotRunning
        case pullFailed(String)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .serverNotRunning:
                return "Ollama is not running. Start it with `ollama serve`."
            case .pullFailed(let reason):
                return "Failed to pull model: \(reason)"
            case .invalidResponse:
                return "Unexpected response from Ollama server."
            }
        }
    }

    // MARK: - Configuration

    public let baseURL: URL
    /// The model name GrembleVoice uses by default.
    public static let defaultModel = "gemma3:4b"

    private let log = Logger(subsystem: "io.gremble.gremblevoice", category: "OllamaManager")

    // MARK: - Init

    public init(baseURL: URL = OllamaRefiner.defaultBaseURL) {
        self.baseURL = baseURL
    }

    // MARK: - Status

    /// Ping the Ollama server and return which models are installed.
    ///
    /// Completes quickly — safe to call on every app launch.
    public func checkStatus() async -> Status {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "GET"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return .notRunning
            }
            let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
            let names = decoded.models.map { $0.name }
            log.info("Ollama running, models: \(names.joined(separator: ", "))")
            return .running(models: names)
        } catch {
            log.info("Ollama not reachable: \(error.localizedDescription)")
            return .notRunning
        }
    }

    /// Whether a specific model is already pulled.
    public func isModelAvailable(_ modelName: String) async -> Bool {
        if case .running(let models) = await checkStatus() {
            // Ollama model names can include a tag (e.g. "gemma3:4b") or just a name.
            return models.contains { $0.hasPrefix(modelName.components(separatedBy: ":").first ?? modelName) }
        }
        return false
    }

    // MARK: - Pull

    /// Pull a model from the Ollama library, reporting download progress.
    ///
    /// - Parameters:
    ///   - modelName: Model name as shown in `ollama list` (e.g. `"gemma3:4b"`).
    ///   - progressHandler: Called with `(fractionComplete, statusMessage)` on each
    ///     server-sent progress event. `fractionComplete` is 0.0–1.0; it may stay at
    ///     0 until Ollama reports byte counts.
    public func pullModel(
        _ modelName: String,
        progressHandler: @Sendable (Double, String) -> Void
    ) async throws {
        let url = baseURL.appendingPathComponent("api/pull")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = PullRequest(model: modelName, stream: true)
        request.httpBody = try JSONEncoder().encode(body)

        log.info("Pulling Ollama model: \(modelName)")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OllamaError.serverNotRunning
        }

        for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            guard let event = try? JSONDecoder().decode(PullEvent.self, from: data) else { continue }

            let fraction: Double
            if let total = event.total, let completed = event.completed, total > 0 {
                fraction = Double(completed) / Double(total)
            } else {
                fraction = event.status == "success" ? 1.0 : 0.0
            }

            log.debug("Pull event: \(event.status) \(Int(fraction * 100))%")
            progressHandler(fraction, event.status)

            if event.status == "success" {
                log.info("Model \(modelName) pulled successfully")
                return
            }
        }
    }

    // MARK: - Codable helpers

    private struct TagsResponse: Decodable {
        let models: [ModelEntry]
        struct ModelEntry: Decodable {
            let name: String
        }
    }

    private struct PullRequest: Encodable {
        let model: String
        let stream: Bool
    }

    private struct PullEvent: Decodable {
        let status: String
        let total: Int?
        let completed: Int?
    }
}
