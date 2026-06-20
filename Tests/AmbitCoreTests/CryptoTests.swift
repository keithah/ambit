import XCTest
@testable import AmbitCore

final class CryptoTests: XCTestCase {
    func testSHA512CryptKnownVector() throws {
        let hash = try PasswordHasher.crypt(password: "password", alg: 6, salt: "salt")
        XCTAssertEqual(hash, "$6$salt$IxDD3jeSOb5eB1CX5LBsqZFVkJdido3OUILO5Ifz5iwMuTS4XMS130MTSuDDl3aCI6WouIL9AjRbLCelDCy.g.")
    }

    func testFinalChallengeHashUsesRouterProvidedSHA256Method() throws {
        let hash = try PasswordHasher.finalHash(username: "root", cipher: "$1$salt$abc", nonce: "nonce", hashMethod: "sha256")

        XCTAssertEqual(hash, "78deb5d4b0fc014039f960e2fea1cae126c49f3e259eef0adbfed3964498c7c9")
    }

    func testFinalChallengeHashDefaultsToMD5ForOlderRouters() throws {
        let hash = try PasswordHasher.finalHash(username: "root", cipher: "$1$salt$abc", nonce: "nonce", hashMethod: nil)

        XCTAssertEqual(hash, "e3bcb2fb5d9496d82215a0aa58a61f35")
    }
}
