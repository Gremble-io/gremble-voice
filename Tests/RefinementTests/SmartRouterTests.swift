import XCTest
@testable import GrembleVoiceRefinement
import GrembleVoiceCore

/// Tests for `SmartRouter` routing and fallback logic using mock refiners.
final class SmartRouterTests: XCTestCase {

    // MARK: - Helpers

    /// A `TextRefiner` that always returns a fixed string.
    struct SuccessRefiner: TextRefiner {
        let result: String
        func refine(text: String, context: RefinementContext?, customPrompt: String?) async throws -> String {
            result
        }
    }

    /// A `TextRefiner` that always throws.
    struct FailingRefiner: TextRefiner {
        let error: Error
        func refine(text: String, context: RefinementContext?, customPrompt: String?) async throws -> String {
            throw error
        }
    }

    // MARK: - Primary success

    func testRouterUsesCustomPrimaryRefiner() async throws {
        let config = SmartRouterConfig(
            primary: .custom(SuccessRefiner(result: "polished text")))
        let router = SmartRouter(config: config)

        let result = try await router.refine(text: "raw text", context: nil, customPrompt: nil)
        XCTAssertEqual(result, "polished text")
    }

    // MARK: - Fallback

    func testRouterFallsBackWhenPrimaryFails() async throws {
        let primary = FailingRefiner(error: TextRefinerError.refinementFailed("primary error"))
        let fallback = SuccessRefiner(result: "fallback result")

        let config = SmartRouterConfig(primary: .custom(primary), fallback: fallback)
        let router = SmartRouter(config: config)

        let result = try await router.refine(text: "raw text", context: nil, customPrompt: nil)
        XCTAssertEqual(result, "fallback result")
    }

    func testRouterPropagatesErrorWhenNoFallback() async {
        let primary = FailingRefiner(error: TextRefinerError.refinementFailed("boom"))
        let config = SmartRouterConfig(primary: .custom(primary))
        let router = SmartRouter(config: config)

        do {
            _ = try await router.refine(text: "raw", context: nil, customPrompt: nil)
            XCTFail("Expected error to be thrown")
        } catch TextRefinerError.refinementFailed(let msg) {
            XCTAssertEqual(msg, "boom")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Config initialisation

    func testOllamaBackendCreatesOllamaRefiner() async throws {
        let url = URL(string: "http://localhost:11434")!
        let config = SmartRouterConfig(primary: .ollama(baseURL: url, model: "gemma3:4b"))
        let router = SmartRouter(config: config)
        // SmartRouter should be created without error
        // We can't inspect the internal refiner type, but we can call loadModel (no-op for Ollama)
        try await router.loadModel()
    }

    func testMLXBackendCreatesMLXRefiner() async throws {
        let config = SmartRouterConfig(primary: .mlx(modelID: MLXRefiner.defaultModelID))
        let router = SmartRouter(config: config)
        // loadModel is a no-op at this point (doesn't download)
        // just verify no crash
        _ = router
    }
}
