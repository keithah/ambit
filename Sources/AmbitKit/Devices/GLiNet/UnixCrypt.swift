import CryptoKit
import Foundation

/// The Unix `crypt(3)` password schemes a GL.iNet router may ask for at login: MD5-crypt (`$1$`),
/// SHA-256-crypt (`$5$`) and SHA-512-crypt (`$6$`). Computed in-process so the password never
/// appears in another program's arguments. macOS's own `crypt` supports none of the three.
enum UnixCrypt {
    enum Scheme: Int, Sendable {
        case md5 = 1, sha256 = 5, sha512 = 6
    }

    struct InvalidSalt: Error, Equatable {}

    /// Returns the full crypt string, for example `$5$salt$hash`. `salt` is the bare salt without
    /// the `$n$` prefix; a `rounds=` parameter is not supported.
    static func hash(password: String, salt: String, scheme: Scheme) throws -> String {
        let password = Array(password.utf8)
        guard !salt.isEmpty, !salt.contains("$"), !salt.hasPrefix("rounds=") else { throw InvalidSalt() }
        switch scheme {
        case .md5:
            let salt = Array(salt.utf8.prefix(8))
            return "$1$" + String(decoding: salt, as: UTF8.self) + "$" + md5Crypt(password, salt)
        case .sha256:
            let salt = Array(salt.utf8.prefix(16))
            return "$5$" + String(decoding: salt, as: UTF8.self) + "$" + shaCrypt(password, salt, SHA256.self, order: sha256Order)
        case .sha512:
            let salt = Array(salt.utf8.prefix(16))
            return "$6$" + String(decoding: salt, as: UTF8.self) + "$" + shaCrypt(password, salt, SHA512.self, order: sha512Order)
        }
    }

    // MARK: MD5-crypt (Poul-Henning Kamp)

    private static func md5Crypt(_ password: [UInt8], _ salt: [UInt8]) -> String {
        let alternate = digest(Insecure.MD5.self, password + salt + password)
        var input = password + Array("$1$".utf8) + salt
        var remaining = password.count
        while remaining > 0 {
            input += alternate.prefix(min(16, remaining))
            remaining -= 16
        }
        var bits = password.count
        while bits != 0 {
            input.append(bits & 1 != 0 ? 0 : (password.first ?? 0))
            bits >>= 1
        }
        var final = digest(Insecure.MD5.self, input)
        for round in 0..<1000 {
            var next: [UInt8] = round & 1 != 0 ? password : final
            if round % 3 != 0 { next += salt }
            if round % 7 != 0 { next += password }
            next += round & 1 != 0 ? final : password
            final = digest(Insecure.MD5.self, next)
        }
        let groups: [(Int, Int, Int)] = [(0, 6, 12), (1, 7, 13), (2, 8, 14), (3, 9, 15), (4, 10, 5)]
        var out = ""
        for (a, b, c) in groups { out += encode(final[a], final[b], final[c], count: 4) }
        return out + encode(0, 0, final[11], count: 2)
    }

    // MARK: SHA-crypt (Ulrich Drepper), default 5000 rounds

    private static func shaCrypt<H: HashFunction>(_ password: [UInt8], _ salt: [UInt8], _ function: H.Type, order: [Int]) -> String {
        let size = H.Digest.byteCount
        let alternate = digest(function, password + salt + password)
        var input = password + salt
        var remaining = password.count
        while remaining > size {
            input += alternate
            remaining -= size
        }
        input += alternate.prefix(remaining)
        var bits = password.count
        while bits > 0 {
            input += bits & 1 != 0 ? alternate : password
            bits >>= 1
        }
        var current = digest(function, input)

        let passwordDigest = digest(function, Array(repeatElement(password, count: password.count).joined()))
        let p = (0..<password.count).map { passwordDigest[$0 % size] }
        let saltDigest = digest(function, Array(repeatElement(salt, count: 16 + Int(current[0])).joined()))
        let s = Array(saltDigest.prefix(salt.count))

        for round in 0..<5000 {
            var next: [UInt8] = round & 1 != 0 ? p : current
            if round % 3 != 0 { next += s }
            if round % 7 != 0 { next += p }
            next += round & 1 != 0 ? current : p
            current = digest(function, next)
        }

        var out = ""
        var index = 0
        while index + 3 <= order.count {
            out += encode(current[order[index]], current[order[index + 1]], current[order[index + 2]], count: 4)
            index += 3
        }
        // The last one or two bytes fill a short final group.
        if size == 32 {
            out += encode(0, current[31], current[30], count: 3)
        } else {
            out += encode(0, 0, current[63], count: 2)
        }
        return out
    }

    /// Byte order of the full three-byte groups, from the reference implementation.
    private static let sha256Order = [
        0, 10, 20, 21, 1, 11, 12, 22, 2, 3, 13, 23, 24, 4, 14, 15, 25, 5, 6, 16, 26, 27, 7, 17, 18, 28, 8, 9, 19, 29,
    ]
    private static let sha512Order = [
        0, 21, 42, 22, 43, 1, 44, 2, 23, 3, 24, 45, 25, 46, 4, 47, 5, 26, 6, 27, 48, 28, 49, 7, 50, 8, 29, 9, 30, 51,
        31, 52, 10, 53, 11, 32, 12, 33, 54, 34, 55, 13, 56, 14, 35, 15, 36, 57, 37, 58, 16, 59, 17, 38, 18, 39, 60,
        40, 61, 19, 62, 20, 41,
    ]

    private static func digest<H: HashFunction>(_ function: H.Type, _ bytes: [UInt8]) -> [UInt8] {
        Array(function.hash(data: bytes))
    }

    private static let alphabet = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// crypt's base-64: 24 bits from three bytes, emitted six bits at a time, lowest first.
    private static func encode(_ high: UInt8, _ middle: UInt8, _ low: UInt8, count: Int) -> String {
        var value = UInt32(high) << 16 | UInt32(middle) << 8 | UInt32(low)
        var out = ""
        for _ in 0..<count {
            out.append(alphabet[Int(value & 0x3F)])
            value >>= 6
        }
        return out
    }
}
