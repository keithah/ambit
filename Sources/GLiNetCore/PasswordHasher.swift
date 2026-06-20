import CryptoKit
import Foundation

public enum PasswordHasher {
    public static func crypt(password: String, alg: Int, salt: String) throws -> String {
        guard [1, 5, 6].contains(alg) else {
            throw JSONRPCClientError.unsupportedHashAlgorithm(alg)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: opensslPath())
        process.arguments = ["passwd", "-\(alg)", "-salt", salt, password]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0, !out.isEmpty else {
            throw JSONRPCClientError.commandFailed(err.isEmpty ? "openssl passwd failed" : err)
        }
        return out
    }

    public static func loginHash(username: String, password: String, alg: Int, salt: String, nonce: String, hashMethod: String? = nil) throws -> String {
        let cipher = try crypt(password: password, alg: alg, salt: salt)
        return try finalHash(username: username, cipher: cipher, nonce: nonce, hashMethod: hashMethod)
    }

    public static func finalHash(username: String, cipher: String, nonce: String, hashMethod: String?) throws -> String {
        let input = "\(username):\(cipher):\(nonce)"
        let data = Data(input.utf8)
        switch hashMethod?.lowercased() {
        case nil, "", "md5":
            return Insecure.MD5.hash(data: data).hexString
        case "sha256", "sha-256":
            return SHA256.hash(data: data).hexString
        case "sha512", "sha-512":
            return SHA512.hash(data: data).hexString
        case let method?:
            throw JSONRPCClientError.commandFailed("Unsupported router challenge hash method \(method).")
        }
    }

    private static func opensslPath() -> String {
        let candidates = [
            "/opt/homebrew/bin/openssl",
            "/usr/local/bin/openssl",
            "/opt/homebrew/opt/openssl@3/bin/openssl",
            "/usr/local/opt/openssl@3/bin/openssl",
            "/usr/bin/openssl"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/openssl"
    }
}

private extension Sequence where Element == UInt8 {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
