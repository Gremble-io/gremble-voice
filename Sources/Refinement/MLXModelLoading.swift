import Foundation
import Hub
import MLXLMCommon
import Tokenizers

// MARK: - Downloader bridge (Hub → MLXLMCommon.Downloader)

/// Wraps `HubApi` from `swift-transformers` as an `MLXLMCommon.Downloader`.
///
/// `swift-transformers` is already in the dependency graph via WhisperKit, so
/// no extra package is required.
struct HubApiDownloader: MLXLMCommon.Downloader {

    private let token: String?

    init(token: String? = nil) {
        self.token = token
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let repo = Hub.Repo(id: id)
        let onlineApi = token.map { HubApi(hfToken: $0) } ?? HubApi.shared
        let localPath = onlineApi.localRepoLocation(repo)
        let cached = FileManager.default.fileExists(atPath: localPath.path)

        let api = cached ? HubApi(hfToken: token, useOfflineMode: true) : onlineApi

        return try await api.snapshot(
            from: repo,
            revision: revision ?? "main",
            matching: patterns.isEmpty ? ["*"] : patterns,
            progressHandler: progressHandler
        )
    }
}

// MARK: - TokenizerLoader bridge (Tokenizers → MLXLMCommon.TokenizerLoader)

/// Wraps `AutoTokenizer` from `swift-transformers` as an `MLXLMCommon.TokenizerLoader`.
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {

    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TransformersTokenizerBridge(upstream)
    }
}

/// Bridges `Tokenizers.Tokenizer` (swift-transformers) to `MLXLMCommon.Tokenizer`.
struct TransformersTokenizerBridge: MLXLMCommon.Tokenizer, @unchecked Sendable {

    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
