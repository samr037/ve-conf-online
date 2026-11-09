import CommonCrypto
import Foundation

/// Authorization for the grid-code access class in VE Configure 9004248.
/// A file token never creates a live authorization: the user must enter the password.
///
/// The password is Victron's and is given to installers only. The entry is checked against a salted PBKDF2-SHA-256
/// hash, and the token written to the file is computed from what the user typed, the way VE Configure encodes an
/// entered password. Same parameters as web/src/lib/engine/gridPassword.ts.
public struct GridPassword: Equatable {
    private let token: [UInt8]

    public init?(_ input: String) {
        let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ".utf8)
        let text = Array(input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().utf8)
        guard text.count == 12 else { return nil }
        var value: UInt64 = 0
        for char in text {
            guard let digit = alphabet.firstIndex(of: char) else { return nil }
            value = (value << 5) | UInt64(digit)
        }
        guard Self.matches(text) else { return nil }
        token = (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    private static let salt: [UInt8] = hex("251dea09d5b5e4a5ab86b51aafb1e6e8")
    private static let iterations: UInt32 = 120_000
    private static let expected: [UInt8] = hex("598ce0dcc8a2215541602d3723b0a82a14135b0406ade1cc7248ac28ad5c0f7f")

    private static func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map { i in
            UInt8(s[s.index(s.startIndex, offsetBy: i)..<s.index(s.startIndex, offsetBy: i + 2)], radix: 16)!
        }
    }

    private static func matches(_ text: [UInt8]) -> Bool {
        var derived = [UInt8](repeating: 0, count: 32)
        let status = text.withUnsafeBufferPointer { pw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), UnsafeRawPointer(pw.baseAddress!).assumingMemoryBound(to: Int8.self),
                                 pw.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                 &derived, derived.count)
        }
        guard status == kCCSuccess else { return false }
        return zip(derived, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Record only the authorization verified in this session. Do not renew unrelated tokens.
    /// Version 1 has no token fields; callers must refuse authorized edits to that format.
    public func authorizeSave(_ config: inout DeviceConfiguration, now: Int64) {
        precondition(config.data.version >= 2)
        config.data.tokens = [token]
        config.data.tokenTime = now
    }
}
