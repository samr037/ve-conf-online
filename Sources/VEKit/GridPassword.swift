import Foundation

/// Authorization for the grid-code access class in VE Configure 9004248.
/// A file token never creates a live authorization: the user must enter the password.
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
        // FUN_004bceac encodes this value; FUN_004bced4 decodes entered passwords.
        guard value == 0x0000000000000000 else { return nil }
        token = (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    /// Record only the authorization verified in this session. Do not renew unrelated tokens.
    /// Version 1 has no token fields; callers must refuse authorized edits to that format.
    public func authorizeSave(_ config: inout DeviceConfiguration, now: Int64) {
        precondition(config.data.version >= 2)
        config.data.tokens = [token]
        config.data.tokenTime = now
    }
}
