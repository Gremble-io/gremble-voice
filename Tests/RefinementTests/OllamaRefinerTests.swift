import XCTest
@testable import GrembleVoiceRefinement
import GrembleVoiceCore

/// Unit tests for `OllamaRefiner` using a mock URLProtocol.
///
/// Integration test requires a running Ollama server:
///   `GREMBLE_INTEGRATION=1 swift test --filter OllamaRefinerTests/testIntegration`
final class OllamaRefinerTests: XCTestCase {

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

    func testRefineReturnsMessageContent() async throws {
        MockURLProtocol.requestHandler = { request in
            let json = """
            {
                "model": "gemma3:4b",
                "message": {"role": "assistant", "content": "Refined output text."}
            }
            """
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let refiner = OllamaRefiner()
        let result = try await refiner.refine(text: "raw input", context: nil, customPrompt: nil)
        XCTAssertEqual(result, "Refined output text.")
    }

    func testRequestTargetsChatEndpoint() async throws {
        var capturedURL: URL?
        MockURLProtocol.requestHandler = { request in
            capturedURL = request.url
            let json = """
            {"message": {"role": "assistant", "content": "ok"}}
            """
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let refiner = OllamaRefiner(
            baseURL: URL(string: "http://localhost:11434")!,
            model: "gemma3:4b"
        )
        _ = try await refiner.refine(text: "hi", context: nil, customPrompt: nil)

        XCTAssertEqual(capturedURL?.path, "/api/chat")
    }

    func testModelNameIsIncludedInRequest() async throws {
        var capturedBody: Data?
        MockURLProtocol.requestHandler = { request in
            capturedBody = request.httpBody
            let json = """
            {"message": {"role": "assistant", "content": "ok"}}
            """
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let refiner = OllamaRefiner(model: "llama3.2:3b")
        _ = try await refiner.refine(text: "hi", context: nil, customPrompt: nil)

        let body = try XCTUnwrap(capturedBody)
        let decoded = try JSONDecoder().decode(ModelSpy.self, from: body)
        XCTAssertEqual(decoded.model, "llama3.2:3b")
    }

    func testStreamFalseIsSetInRequest() async throws {
        var capturedBody: Data?
        MockURLProtocol.requestHandler = { request in
            capturedBody = request.httpBody
            let json = """
            {"message": {"role": "assistant", "content": "ok"}}
            """
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let refiner = OllamaRefiner()
        _ = try await refiner.refine(text: "hi", context: nil, customPrompt: nil)

        let body = try XCTUnwrap(capturedBody)
        let decoded = try JSONDecoder().decode(StreamSpy.self, from: body)
        XCTAssertFalse(decoded.stream)
    }

    func testThrowsOnHTTPError() async {
        MockURLProtocol.requestHandler = { request in
            return (MockURLProtocol.response(for: request.url!, statusCode: 500),
                    "Internal server error".data(using: .utf8)!)
        }

        let refiner = OllamaRefiner()
        do {
            _ = try await refiner.refine(text: "hi", context: nil, customPrompt: nil)
            XCTFail("Expected network error")
        } catch TextRefinerError.networkError(let msg) {
            XCTAssertTrue(msg.contains("500"))
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    func testCustomPromptOverridesSystemMessage() async throws {
        var systemContent = ""
        MockURLProtocol.requestHandler = { request in
            let body = try JSONDecoder().decode(MessagesSpy.self, from: request.httpBody!)
            systemContent = body.messages.first(where: { $0.role == "system" })?.content ?? ""
            let json = """
            {"message": {"role": "assistant", "content": "ok"}}
            """
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let refiner = OllamaRefiner()
        _ = try await refiner.refine(
            text: "hi", context: nil, customPrompt: "My custom prompt")
        XCTAssertEqual(systemContent, "My custom prompt")
    }

    // MARK: - Integration

    func testIntegrationOllamaRefinesText() async throws {
        guard ProcessInfo.processInfo.environment["GREMBLE_INTEGRATION"] != nil else {
            throw XCTSkip("Set GREMBLE_INTEGRATION=1 and have Ollama running to run this test")
        }

        // Unregister mock so real network is used.
        URLProtocol.unregisterClass(MockURLProtocol.self)

        let refiner = OllamaRefiner()
        let result = try await refiner.refine(
            text: "uh i want to um test the the ollama refiner",
            context: nil,
            customPrompt: nil
        )
        XCTAssertFalse(result.isEmpty)
        print("Ollama refined: \(result)")
    }
}

// MARK: - Spy types

private struct ModelSpy: Decodable { let model: String }
private struct StreamSpy: Decodable { let stream: Bool }
private struct MessagesSpy: Decodable {
    let messages: [MessageItem]
    struct MessageItem: Decodable {
        let role: String
        let content: String
    }
}
