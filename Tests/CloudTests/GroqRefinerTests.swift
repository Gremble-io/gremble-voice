import XCTest
@testable import GrembleVoiceCloud
import GrembleVoiceCore

final class GroqRefinerTests: XCTestCase {

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
                "choices": [
                    {"message": {"role": "assistant", "content": "Clean text here."}}
                ]
            }
            """
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let refiner = GroqRefiner(apiKey: "test-key")
        let result = try await refiner.refine(text: "raw input", context: nil, customPrompt: nil)
        XCTAssertEqual(result, "Clean text here.")
    }

    func testRequestHitsGroqEndpoint() async throws {
        var capturedURL: URL?
        MockURLProtocol.requestHandler = { request in
            capturedURL = request.url
            let json = """
            {"choices": [{"message": {"role": "assistant", "content": "ok"}}]}
            """
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let refiner = GroqRefiner(apiKey: "test")
        _ = try await refiner.refine(text: "hi", context: nil, customPrompt: nil)

        XCTAssertEqual(capturedURL?.host, "api.groq.com")
    }

    func testDefaultModelIsLlama() async throws {
        var capturedModel = ""
        MockURLProtocol.requestHandler = { request in
            let body = try JSONDecoder().decode(ModelSpy.self, from: request.httpBody!)
            capturedModel = body.model
            let json = """
            {"choices": [{"message": {"role": "assistant", "content": "ok"}}]}
            """
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let refiner = GroqRefiner(apiKey: "test")
        _ = try await refiner.refine(text: "hi", context: nil, customPrompt: nil)
        XCTAssertEqual(capturedModel, "llama-3.1-70b-versatile")
    }
}

private struct ModelSpy: Decodable { let model: String }
