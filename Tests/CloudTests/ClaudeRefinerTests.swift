import XCTest
@testable import GrembleVoiceCloud
import GrembleVoiceCore

final class ClaudeRefinerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    // MARK: - Happy path

    func testRefineReturnsContentFromResponse() async throws {
        MockURLProtocol.requestHandler = { request in
            let json = """
            {
                "id": "msg_01",
                "type": "message",
                "content": [{"type": "text", "text": "The quick brown fox."}],
                "model": "claude-3-5-haiku-latest",
                "stop_reason": "end_turn",
                "usage": {"input_tokens": 10, "output_tokens": 5}
            }
            """
            let url = request.url ?? URL(string: "https://api.anthropic.com")!
            return (MockURLProtocol.response(for: url), json.data(using: .utf8)!)
        }

        let refiner = ClaudeRefiner(apiKey: "test-key")
        let result = try await refiner.refine(
            text: "uh the quick brown fox um",
            context: nil,
            customPrompt: nil
        )
        XCTAssertEqual(result, "The quick brown fox.")
    }

    func testRefineIncludesContextInSystemPrompt() async throws {
        var capturedBody: Data?
        MockURLProtocol.requestHandler = { request in
            capturedBody = request.httpBody
            let json = """
            {"content": [{"type": "text", "text": "refined"}], "stop_reason": "end_turn"}
            """
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let context = RefinementContext(activeAppName: "Slack", selectedText: nil, clipboardText: nil, browserURL: nil)
        let refiner = ClaudeRefiner(apiKey: "test-key")
        _ = try await refiner.refine(text: "hello", context: context, customPrompt: nil)

        let body = try XCTUnwrap(capturedBody)
        let decoded = try JSONDecoder().decode(ClaudeRequestSpy.self, from: body)
        XCTAssertTrue(decoded.system.contains("Slack"), "System prompt should include app name")
    }

    func testRefineUsesCustomPromptWhenProvided() async throws {
        var capturedSystem = ""
        MockURLProtocol.requestHandler = { request in
            let body = try JSONDecoder().decode(ClaudeRequestSpy.self, from: request.httpBody!)
            capturedSystem = body.system
            let json = """
            {"content": [{"type": "text", "text": "done"}], "stop_reason": "end_turn"}
            """
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let refiner = ClaudeRefiner(apiKey: "test-key")
        _ = try await refiner.refine(
            text: "hello",
            context: nil,
            customPrompt: "My custom system prompt"
        )
        XCTAssertEqual(capturedSystem, "My custom system prompt")
    }

    func testRefineThrowsOnHTTPError() async {
        MockURLProtocol.requestHandler = { request in
            let errorJSON = #"{"error": {"type": "authentication_error", "message": "Invalid API key"}}"#
            return (MockURLProtocol.response(for: request.url!, statusCode: 401),
                    errorJSON.data(using: .utf8)!)
        }

        let refiner = ClaudeRefiner(apiKey: "bad-key")
        do {
            _ = try await refiner.refine(text: "hello", context: nil, customPrompt: nil)
            XCTFail("Expected network error to be thrown")
        } catch TextRefinerError.networkError(let msg) {
            XCTAssertTrue(msg.contains("401"), "Error should mention HTTP 401")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testRequestHeadersAreCorrect() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let json = """
            {"content": [{"type": "text", "text": "ok"}], "stop_reason": "end_turn"}
            """
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let refiner = ClaudeRefiner(apiKey: "sk-test-123")
        _ = try await refiner.refine(text: "hi", context: nil, customPrompt: nil)

        let req = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-test-123")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    // MARK: - Custom model

    func testCustomModelIsUsedInRequest() async throws {
        var capturedModel = ""
        MockURLProtocol.requestHandler = { request in
            let body = try JSONDecoder().decode(ClaudeRequestSpy.self, from: request.httpBody!)
            capturedModel = body.model
            let json = """
            {"content": [{"type": "text", "text": "ok"}], "stop_reason": "end_turn"}
            """
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let refiner = ClaudeRefiner(apiKey: "test", model: "claude-opus-4-6")
        _ = try await refiner.refine(text: "hi", context: nil, customPrompt: nil)
        XCTAssertEqual(capturedModel, "claude-opus-4-6")
    }
}

// MARK: - Spy types

private struct ClaudeRequestSpy: Decodable {
    let model: String
    let system: String
}
