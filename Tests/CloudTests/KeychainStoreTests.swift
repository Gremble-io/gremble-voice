import XCTest
@testable import GrembleVoiceCloud

final class KeychainStoreTests: XCTestCase {

    // Use a unique service per test run to avoid collisions with other test runs.
    private let service = "io.gremble.test.\(UUID().uuidString)"

    private var store: KeychainStore { KeychainStore(service: service) }

    override func tearDown() {
        // Clean up any keys we may have written.
        store.delete(key: "testKey")
        store.delete(key: "key1")
        store.delete(key: "key2")
        super.tearDown()
    }

    // MARK: - Basic CRUD

    func testSaveAndLoad() {
        let result = store.save(key: "testKey", value: "secret-api-key")
        XCTAssertTrue(result)

        let loaded = store.load(key: "testKey")
        XCTAssertEqual(loaded, "secret-api-key")
    }

    func testLoadMissingKeyReturnsNil() {
        let loaded = store.load(key: "nonexistent")
        XCTAssertNil(loaded)
    }

    func testDeleteRemovesKey() {
        store.save(key: "testKey", value: "value")
        let deleted = store.delete(key: "testKey")
        XCTAssertTrue(deleted)

        let loaded = store.load(key: "testKey")
        XCTAssertNil(loaded)
    }

    func testDeleteMissingKeySucceeds() {
        let result = store.delete(key: "doesNotExist")
        XCTAssertTrue(result, "Deleting a missing key should still succeed")
    }

    func testOverwriteExistingKey() {
        store.save(key: "testKey", value: "original")
        store.save(key: "testKey", value: "updated")

        let loaded = store.load(key: "testKey")
        XCTAssertEqual(loaded, "updated")
    }

    // MARK: - Service isolation

    func testDifferentServicesAreIsolated() {
        let storeA = KeychainStore(service: service + ".A")
        let storeB = KeychainStore(service: service + ".B")

        storeA.save(key: "key1", value: "valueA")
        storeB.save(key: "key1", value: "valueB")

        XCTAssertEqual(storeA.load(key: "key1"), "valueA")
        XCTAssertEqual(storeB.load(key: "key1"), "valueB")

        storeA.delete(key: "key1")
        storeB.delete(key: "key1")
    }

    // MARK: - Unicode values

    func testUnicodeValueRoundTrips() {
        let emoji = "🎙️🦊 héllo wörld"
        store.save(key: "testKey", value: emoji)
        XCTAssertEqual(store.load(key: "testKey"), emoji)
    }
}
