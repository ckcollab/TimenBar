import XCTest
@testable import TimenBar

final class KeychainStoreTests: XCTestCase {
    func testTokenLifecycle() async throws {
        let store = KeychainStore(service: "app.timenbar.tests.\(UUID().uuidString)")
        let account = "tokens"
        let token = OAuthTokenSet(accessToken: "secret", tokenType: "Bearer", refreshToken: "refresh")

        try await store.save(token, account: account)
        let loaded = try await store.load(OAuthTokenSet.self, account: account)
        XCTAssertEqual(loaded?.accessToken, "secret")
        try await store.delete(account: account)
        let deleted = try await store.load(OAuthTokenSet.self, account: account)
        XCTAssertNil(deleted)
    }
}
