import XCTest
@testable import GrembleVoiceRefinement
import GrembleVoiceCore

/// Unit tests for `MLXRefiner` that do not require a downloaded model.
///
/// Integration tests (actual model load + inference) are skipped unless
/// `GREMBLE_INTEGRATION=1` is set:
///   `GREMBLE_INTEGRATION=1 swift test --filter MLXRefinerTests`
final class MLXRefinerTests: XCTestCase {

    // MARK: - Unloaded state

    func testIsModelLoadedFalseInitially() async {
        let refiner = MLXRefiner()
        let loaded = await refiner.isModelLoaded
        XCTAssertFalse(loaded, "isModelLoaded should be false before loadModel()")
    }

    func testRefineThrowsWhenModelNotLoaded() async {
        let refiner = MLXRefiner()
        do {
            _ = try await refiner.refine(text: "hello", context: nil, customPrompt: nil)
            XCTFail("Expected TextRefinerError.modelNotLoaded")
        } catch TextRefinerError.modelNotLoaded {
            // expected
        } catch {
            XCTFail("Expected TextRefinerError.modelNotLoaded, got \(error)")
        }
    }

    func testUnloadBeforeLoadIsNoOp() async {
        let refiner = MLXRefiner()
        // Should not crash
        await refiner.unloadModel()
        let loaded = await refiner.isModelLoaded
        XCTAssertFalse(loaded)
    }

    func testCustomModelIDIsUsed() async {
        let refiner = MLXRefiner(modelID: "mlx-community/some-model")
        // Just verify we can create it; model is not loaded
        let loaded = await refiner.isModelLoaded
        XCTAssertFalse(loaded)
    }

    // MARK: - Integration (model download required)

    func testIntegrationLoadAndRefine() async throws {
        guard ProcessInfo.processInfo.environment["GREMBLE_INTEGRATION"] != nil else {
            throw XCTSkip("Set GREMBLE_INTEGRATION=1 to run MLX integration tests")
        }

        let refiner = MLXRefiner()
        try await refiner.loadModel { p in print("MLX load: \(Int(p * 100))%") }

        let result = try await refiner.refine(
            text: "uh the quick brown fox um jumps over the the lazy dog",
            context: nil,
            customPrompt: nil
        )
        XCTAssertFalse(result.isEmpty, "Expected non-empty refined text")
        print("MLX refined: \(result)")

        await refiner.unloadModel()
        let loaded = await refiner.isModelLoaded
        XCTAssertFalse(loaded)
    }
}
