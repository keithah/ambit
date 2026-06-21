import XCTest
@testable import AmbitCore

final class CredentialStoreTests: XCTestCase {
    func testCredentialKeysAreScopedByProviderAndAccount() throws {
        let store = MemoryCredentialStore()
        try store.setCredential("router-secret", for: CredentialKey(providerID: ProviderIDs.router, id: "password", account: "root"))
        try store.setCredential("api-secret", for: CredentialKey(providerID: "demo.api", id: "password", account: "root"))

        XCTAssertEqual(try store.credential(CredentialKey(providerID: ProviderIDs.router, id: "password", account: "root")), "router-secret")
        XCTAssertEqual(try store.credential(CredentialKey(providerID: "demo.api", id: "password", account: "root")), "api-secret")
    }

    func testRouterPasswordCompatibilityUsesScopedCredentialKey() throws {
        let store = MemoryCredentialStore()

        try store.setPassword("secret", account: "root")

        XCTAssertEqual(try store.credential(.routerPassword(account: "root")), "secret")

        try store.setCredential("updated", for: .routerPassword(account: "root"))

        XCTAssertEqual(try store.password(account: "root"), "updated")
    }
}

private final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var credentials: [CredentialKey: String] = [:]

    func credential(_ key: CredentialKey) throws -> String? {
        credentials[key]
    }

    func setCredential(_ value: String?, for key: CredentialKey) throws {
        credentials[key] = value
    }
}
