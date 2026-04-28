import XCTest
@testable import GrembleVoiceCloud
import GrembleVoiceCore

final class OpenAITranscriberTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testTranscribeDataReturnsText() async throws {
        MockURLProtocol.requestHandler = { request in
            let json = #"{"text": "  Hello world.  "}"#
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let transcriber = OpenAITranscriber(apiKey: "test-key")
        let result = try await transcriber.transcribe(
            audioData: Data([0, 1, 2, 3]),
            fileExtension: "wav"
        )
        XCTAssertEqual(result.text, "Hello world.", "Text should be trimmed")
    }

    func testTranscribeHitsWhisperEndpoint() async throws {
        var capturedURL: URL?
        MockURLProtocol.requestHandler = { request in
            capturedURL = request.url
            let json = #"{"text": "test"}"#
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let transcriber = OpenAITranscriber(apiKey: "key")
        _ = try await transcriber.transcribe(audioData: Data([0]), fileExtension: "wav")
        XCTAssertEqual(capturedURL?.host, "api.openai.com")
        XCTAssertEqual(capturedURL?.path, "/v1/audio/transcriptions")
    }

    func testTranscribeBearerTokenIsSet() async throws {
        var authHeader = ""
        MockURLProtocol.requestHandler = { request in
            authHeader = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let json = #"{"text": "ok"}"#
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let transcriber = OpenAITranscriber(apiKey: "sk-openai-xyz")
        _ = try await transcriber.transcribe(audioData: Data([0]), fileExtension: "wav")
        XCTAssertEqual(authHeader, "Bearer sk-openai-xyz")
    }

    func testTranscribeThrowsOnHTTPError() async {
        MockURLProtocol.requestHandler = { request in
            return (MockURLProtocol.response(for: request.url!, statusCode: 413),
                    "File too large".data(using: .utf8)!)
        }

        let transcriber = OpenAITranscriber(apiKey: "key")
        do {
            _ = try await transcriber.transcribe(audioData: Data([0]), fileExtension: "wav")
            XCTFail("Expected error")
        } catch CloudTranscriptionError.requestFailed(let code, _) {
            XCTAssertEqual(code, 413)
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    func testTranscribeIsMultipart() async throws {
        var contentType = ""
        MockURLProtocol.requestHandler = { request in
            contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
            let json = #"{"text": "ok"}"#
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let transcriber = OpenAITranscriber(apiKey: "key")
        _ = try await transcriber.transcribe(audioData: Data([0]), fileExtension: "wav")
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data"), "Should be multipart/form-data")
    }

    func testProcessingTimeIsPositive() async throws {
        MockURLProtocol.requestHandler = { request in
            let json = #"{"text": "result"}"#
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let transcriber = OpenAITranscriber(apiKey: "key")
        let result = try await transcriber.transcribe(audioData: Data([0]), fileExtension: "wav")
        XCTAssertGreaterThan(result.processingTime, 0)
    }
}

final class GroqTranscriberTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testTranscribeHitsGroqEndpoint() async throws {
        var capturedURL: URL?
        MockURLProtocol.requestHandler = { request in
            capturedURL = request.url
            let json = #"{"text": "test"}"#
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let transcriber = GroqTranscriber(apiKey: "key")
        _ = try await transcriber.transcribe(audioData: Data([0]), fileExtension: "wav")
        XCTAssertEqual(capturedURL?.host, "api.groq.com")
    }

    func testDefaultModelIsWhisperLargeV3() async throws {
        var capturedBody = Data()
        MockURLProtocol.requestHandler = { request in
            capturedBody = request.httpBody ?? Data()
            let json = #"{"text": "ok"}"#
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let transcriber = GroqTranscriber(apiKey: "key")
        _ = try await transcriber.transcribe(audioData: Data([0]), fileExtension: "wav")

        // Verify model name appears in multipart body
        let bodyString = String(data: capturedBody, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyString.contains("whisper-large-v3"), "Default model should be whisper-large-v3")
    }
}

final class DeepgramTranscriberTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testTranscribeReturnsFirstAlternative() async throws {
        MockURLProtocol.requestHandler = { request in
            let json = """
            {
                "results": {
                    "channels": [
                        {
                            "alternatives": [
                                {"transcript": "Hello Deepgram."},
                                {"transcript": "Second alternative."}
                            ]
                        }
                    ]
                }
            }
            """
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let transcriber = DeepgramTranscriber(apiKey: "key")
        let result = try await transcriber.transcribe(audioData: Data([0]), fileExtension: "wav")
        XCTAssertEqual(result.text, "Hello Deepgram.")
    }

    func testTranscribeHitsDeepgramEndpoint() async throws {
        var capturedURL: URL?
        MockURLProtocol.requestHandler = { request in
            capturedURL = request.url
            let json = """
            {"results": {"channels": [{"alternatives": [{"transcript": "ok"}]}]}}
            """
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let transcriber = DeepgramTranscriber(apiKey: "key")
        _ = try await transcriber.transcribe(audioData: Data([0]), fileExtension: "wav")
        XCTAssertEqual(capturedURL?.host, "api.deepgram.com")
    }

    func testTranscribeUsesTokenAuth() async throws {
        var authHeader = ""
        MockURLProtocol.requestHandler = { request in
            authHeader = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let json = """
            {"results": {"channels": [{"alternatives": [{"transcript": "ok"}]}]}}
            """
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let transcriber = DeepgramTranscriber(apiKey: "dg-key-abc")
        _ = try await transcriber.transcribe(audioData: Data([0]), fileExtension: "wav")
        XCTAssertEqual(authHeader, "Token dg-key-abc")
    }

    func testModelIsPassedAsQueryParam() async throws {
        var capturedURL: URL?
        MockURLProtocol.requestHandler = { request in
            capturedURL = request.url
            let json = """
            {"results": {"channels": [{"alternatives": [{"transcript": "ok"}]}]}}
            """
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let transcriber = DeepgramTranscriber(apiKey: "key", model: "nova-3")
        _ = try await transcriber.transcribe(audioData: Data([0]), fileExtension: "wav")

        let query = URLComponents(url: capturedURL!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "model" })?.value
        XCTAssertEqual(query, "nova-3")
    }

    func testDeepgramSendsRawBody() async throws {
        var bodyLength = 0
        MockURLProtocol.requestHandler = { request in
            bodyLength = request.httpBody?.count ?? 0
            let json = """
            {"results": {"channels": [{"alternatives": [{"transcript": "ok"}]}]}}
            """
            return (MockURLProtocol.response(for: request.url!), json.data(using: .utf8)!)
        }

        let audioData = Data(repeating: 0xFF, count: 1024)
        let transcriber = DeepgramTranscriber(apiKey: "key")
        _ = try await transcriber.transcribe(audioData: audioData, fileExtension: "wav")
        XCTAssertEqual(bodyLength, 1024, "Deepgram should send raw audio bytes (no multipart wrapper)")
    }
}
