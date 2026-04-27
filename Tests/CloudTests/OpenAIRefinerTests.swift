import XCTest
@testable import GrembleVoiceCloud
import GrembleVoiceCore

final class OpenAIRefinerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testRefineReturnsChoiceContent() async throws {
        MockURLProtocol.requestHandler = { request in
            let json = """
            {
                "id": "chatcmpl-abc",
                "choices": [
                    {"message": {"role": "assistant", "content": "The quick brown fox."}}
                ]
            }
            """
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let refiner = OpenAIRefiner(apiKey: "test-key")
        let result = try await refiner.refine(
            text: "uh the quick brown fox um",
            context: nil,
            customPrompt: nil
        )
        XCTAssertEqual(result, "The quick brown fox.")
    }

    func testBearerTokenIsSet() async throws {
        var capturedAuth = ""
        MockURLProtocol.requestHandler = { request in
            capturedAuth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let json = """
            {"choices": [{"message": {"role": "assistant", "content": "ok"}}]}
            """
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let refiner = OpenAIRefiner(apiKey: "sk-openai-abc")
        _ = try await refiner.refine(text: "hi", context: nil, customPrompt: nil)
        XCTAssertEqual(capturedAuth, "Bearer sk-openai-abc")
    }

    func testDefaultModelIsGPT4oMini() async throws {
        var capturedModel = ""
        MockURLProtocol.requestHandler = { request in
            let body = try JSONDecoder().decode(ModelSpy.self, from: request.httpBody!)
            capturedModel = body.model
            let json = """
            {"choices": [{"message": {"role": "assistant", "content": "ok"}}]}
            """
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let refiner = OpenAIRefiner(apiKey: "test")
        _ = try await refiner.refine(text: "hi", context: nil, customPrompt: nil)
        XCTAssertEqual(capturedModel, "gpt-4o-mini")
    }

    func testThrowsOnHTTPError() async {
        MockURLProtocol.requestHandler = { request in
            return (MockURLProtocol.response(for: request.url!, statusCode: 429),
                    "Rate limit exceeded".data(using: .utf8)!)
        }

        let refiner = OpenAIRefiner(apiKey: "test")
        do {
            _ = try await refiner.refine(text: "hi", context: nil, customPrompt: nil)
            XCTFail("Expected error")
        } catch TextRefinerError.networkError(let msg) {
            XCTAssertTrue(msg.contains("429"))
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }
}

private struct ModelSpy: Decodable { let model: String }
