import Foundation

/// MK2 "setting info" record: how a raw 16-bit setting maps to a physical value.
/// `display = scale * (raw + offset)`; `scaleRaw` 0 means the device does not support the setting.
public struct SettingInfo: Equatable, Sendable {
    public var scaleRaw: Int16
    public var offset: Int16
    public var defaultRaw: UInt16
    public var minRaw: UInt16
    /// For flag words this is the mask of supported bits.
    public var maxRaw: UInt16

    public var isSupported: Bool { scaleRaw != 0 }
    public var scale: Double {
        scaleRaw > 0 ? Double(scaleRaw) : scaleRaw < 0 ? 1 / Double(-Int(scaleRaw)) : 0
    }
    public func display(_ raw: UInt16) -> Double { scale * (Double(raw) + Double(offset)) }
    /// Nearest raw value for a physical value, clamped to the device range.
    /// Ties round to even, like Delphi `Round` in VE Configure. `nil` for an unsupported setting or a
    /// non-finite value (NaN, ±∞), which must never reach the device.
    public func rawValue(for value: Double) -> UInt16? {
        guard isSupported, value.isFinite else { return nil }
        let r = (value / scale - Double(offset)).rounded(.toNearestOrEven)
        guard r.isFinite else { return nil }
        return UInt16(clamping: Int(min(max(r, Double(minRaw)), Double(maxRaw))))
    }

    /// `rawValue(for:)`, falling back to the current default when the value cannot be encoded.
    /// Prefer `rawValue(for:)` so a NaN is refused instead of silently replaced.
    public func raw(for value: Double) -> UInt16 { rawValue(for: value) ?? defaultRaw }
    /// Smallest step between two displayable values.
    public var step: Double { scale }
}

/// `BareSettingInfo`: what the device reports about each of its settings, plus the firmware grid-code table.
public struct DeviceSettingInfo: Equatable, Sendable {
    public var version: UInt32
    public var firmware: UInt32
    public var configResponseChar: UInt8
    public var records: [SettingInfo]
    public var flagAttributes: [UInt8]
    public var settingAttributes: [UInt8]
    /// Raw firmware grid-code table (version >= 3). Kept verbatim; see `GridTable`.
    public var gridTable: [UInt8]?
    var trailing: [UInt8]

    init(body: [UInt8]) throws {
        var r = ByteReader(body)
        version = try r.u32()
        guard version < 5 else { throw FormatError.unsupportedVersion(section: "BareSettingInfo", version: version) }
        firmware = try r.u32()
        configResponseChar = try r.u8()
        let n = Int(try r.u16())
        guard n % 10 == 0 else {
            throw FormatError.malformed("BareSettingInfo: setting records are \(n) bytes, not a multiple of 10.")
        }
        guard n / 10 <= DeviceSettingData.maxValues else {
            throw FormatError.malformed("BareSettingInfo: \(n / 10) setting records, at most \(DeviceSettingData.maxValues) exist.")
        }
        let recs = try r.bytes(n)
        var records: [SettingInfo] = []
        var rr = ByteReader(recs)
        for _ in 0..<(n / 10) {
            records.append(SettingInfo(scaleRaw: Int16(bitPattern: try rr.u16()), offset: Int16(bitPattern: try rr.u16()),
                                       defaultRaw: try rr.u16(), minRaw: try rr.u16(), maxRaw: try rr.u16()))
        }
        self.records = records
        if version >= 2 {
            flagAttributes = try r.bytes(Int(try r.u16()))
            settingAttributes = try r.bytes(Int(try r.u16()))
        } else {
            flagAttributes = []; settingAttributes = []
        }
        gridTable = version > 2 ? try r.bytes(Int(try r.u16())) : nil
        trailing = try r.bytes(r.remaining)
    }

    func encoded() -> [UInt8] {
        var w = ByteWriter()
        w.u32(version); w.u32(firmware); w.u8(configResponseChar)
        w.u16(UInt16(records.count * 10))
        for s in records {
            w.u16(UInt16(bitPattern: s.scaleRaw)); w.u16(UInt16(bitPattern: s.offset))
            w.u16(s.defaultRaw); w.u16(s.minRaw); w.u16(s.maxRaw)
        }
        if version >= 2 {
            w.u16(UInt16(flagAttributes.count)); w.bytes(flagAttributes)
            w.u16(UInt16(settingAttributes.count)); w.bytes(settingAttributes)
        }
        if let gridTable { w.u16(UInt16(gridTable.count)); w.bytes(gridTable) }
        w.bytes(trailing)
        return w.data
    }

    public func info(_ id: Int) -> SettingInfo? { records.indices.contains(id) ? records[id] : nil }

    /// Settings that are grid-code protected on every firmware: the grid code (81) and the grid words (128…191).
    public static func isGridProtected(setting id: Int) -> Bool { id == 81 || (128...191).contains(id) }
    /// `@_ShortCircuitIsFatal`, the only protected flag bit seen.
    public static func isGridProtected(flag n: Int) -> Bool { n == 64 }

    /// Bit 7: hidden/locked in the UI for this firmware. Bit 0: protected (grid code / installer password).
    public func isHidden(setting id: Int) -> Bool {
        settingAttributes.indices.contains(id) && settingAttributes[id] & 0x80 != 0
    }
    /// Fails closed: without an attribute byte (version 1 files, short tables) the grid items stay protected.
    public func isProtected(setting id: Int) -> Bool {
        settingAttributes.indices.contains(id) ? settingAttributes[id] & 0x01 != 0 : Self.isGridProtected(setting: id)
    }
    public func isHidden(flag n: Int) -> Bool { flagAttributes.indices.contains(n) && flagAttributes[n] & 0x80 != 0 }
    public func isProtected(flag n: Int) -> Bool {
        flagAttributes.indices.contains(n) ? flagAttributes[n] & 0x01 != 0 : Self.isGridProtected(flag: n)
    }
}

/// `BareSettingData`: the device's actual setting values and its assistant program memory.
public struct DeviceSettingData: Equatable, Sendable {
    public var version: UInt32
    public var deviceID: UInt32
    public var firmwareAlt: UInt32
    public var obj20: UInt8 = 0xFF
    public var obj21: UInt8 = 0
    public var byte8: UInt8
    public var firmware: UInt32
    public var firmwareExtra: [UInt8]
    public var configResponseChar: UInt8
    public var deviceRecord: [UInt8]
    public var serial: String?
    public var tokens: [[UInt8]] = []
    public var tokenTime: Int64 = 0
    public var readTime: Int64 = 0
    public var values: [UInt16]
    /// 4096-byte assistant program image (0xFF = unprogrammed).
    public var assistantMemory: [UInt8]
    /// Original RLE token boundaries, so an untouched memory image re-encodes byte for byte.
    var rleTokens: [RLE.Token]?

    /// VE Configure reads at most 0x180 bytes of values (settings 0…191) and skips the rest.
    public static let maxValues = 192
    /// Size of the assistant program memory of every VE.Bus device.
    public static let assistantMemorySize = 4096

    init(body: [UInt8]) throws {
        var r = ByteReader(body)
        version = try r.u32()
        guard version < 4 else { throw FormatError.unsupportedVersion(section: "BareSettingData", version: version) }
        deviceID = try r.u32()
        firmwareAlt = try r.u32()
        if version >= 3 { obj20 = try r.u8(); obj21 = try r.u8() }
        byte8 = try r.u8()
        firmware = try r.u32()
        firmwareExtra = try r.bytes(Int(try r.u16()))
        configResponseChar = try r.u8()
        deviceRecord = try r.bytes(9)
        if version > 1 {
            serial = try r.shortString()
            let count = Int(try r.u16())
            for _ in 0..<count { tokens.append(try r.bytes(Int(try r.u16()))) }
            tokenTime = Int64(bitPattern: UInt64(try r.u32()) | UInt64(try r.u32()) << 32)
            readTime = Int64(bitPattern: UInt64(try r.u32()) | UInt64(try r.u32()) << 32)
        }
        let n = Int(try r.u16())
        guard n % 2 == 0 else { throw FormatError.malformed("BareSettingData: values are \(n) bytes, not a whole number of words.") }
        var vr = ByteReader(try r.bytes(n))
        values = try (0..<min(n / 2, Self.maxValues)).map { _ in try vr.u16() }
        let decoded = try RLE.decode(try r.bytes(r.remaining), limit: Self.assistantMemorySize)
        guard decoded.memory.count == Self.assistantMemorySize else {
            throw FormatError.malformed("BareSettingData: assistant memory is \(decoded.memory.count) bytes, expected \(Self.assistantMemorySize).")
        }
        assistantMemory = decoded.memory
        rleTokens = decoded.tokens
    }

    func encoded() -> [UInt8] {
        var w = ByteWriter()
        w.u32(version); w.u32(deviceID); w.u32(firmwareAlt)
        if version >= 3 { w.u8(obj20); w.u8(obj21) }
        w.u8(byte8); w.u32(firmware)
        w.u16(UInt16(firmwareExtra.count)); w.bytes(firmwareExtra)
        w.u8(configResponseChar); w.bytes(deviceRecord)
        if version > 1 {
            w.shortString(serial ?? "")
            w.u16(UInt16(tokens.count))
            for t in tokens { w.u16(UInt16(t.count)); w.bytes(t) }
            for t in [tokenTime, readTime] {
                let u = UInt64(bitPattern: t)
                w.u32(UInt32(u & 0xffff_ffff)); w.u32(UInt32(u >> 32))
            }
        }
        w.u16(UInt16(values.count * 2))
        for v in values { w.u16(v) }
        w.bytes(RLE.encode(assistantMemory, tokens: rleTokens))
        return w.data
    }
}

/// Run-length coding of the assistant memory (VEConfig `FUN_004bd71c` / `FUN_004bd51c`).
/// Tokens repeat to the end: `[u16 n][n literal bytes][u8 fill][u16 count]`.
public enum RLE {
    struct Token: Equatable, Sendable { var literal: Int; var fill: UInt8; var count: Int }

    /// Throws as soon as the output would exceed `limit` bytes (a few KB of tokens can claim gigabytes).
    static func decode(_ bytes: [UInt8], limit: Int = DeviceSettingData.assistantMemorySize) throws -> (memory: [UInt8], tokens: [Token]) {
        var r = ByteReader(bytes)
        var mem: [UInt8] = []
        var tokens: [Token] = []
        while !r.isAtEnd {
            let lit = try r.bytes(Int(try r.u16()))
            let fill = try r.u8()
            let count = Int(try r.u16())
            guard mem.count + lit.count + count <= limit else { throw FormatError.tooLarge("Assistant memory", limit: limit) }
            tokens.append(Token(literal: lit.count, fill: fill, count: count))
            mem += lit + [UInt8](repeating: fill, count: count)
        }
        return (mem, tokens)
    }

    static func encode(_ mem: [UInt8], tokens: [Token]?) -> [UInt8] {
        // Reuse the original boundaries only if they still describe this exact image.
        if let tokens, tokens.reduce(0, { $0 + $1.literal + $1.count }) == mem.count {
            var p = 0
            var ok = true
            for t in tokens {
                if !mem[(p + t.literal)..<(p + t.literal + t.count)].allSatisfy({ $0 == t.fill }) { ok = false; break }
                p += t.literal + t.count
            }
            if ok { return emit(mem, tokens) }
        }
        return emit(mem, canonicalTokens(mem))
    }

    private static func emit(_ mem: [UInt8], _ tokens: [Token]) -> [UInt8] {
        var w = ByteWriter()
        var p = 0
        for t in tokens {
            w.u16(UInt16(t.literal)); w.bytes(Array(mem[p..<p + t.literal]))
            w.u8(t.fill); w.u16(UInt16(t.count))
            p += t.literal + t.count
        }
        return w.data
    }

    /// Literal runs, then fill runs of at least 6 equal bytes.
    static func canonicalTokens(_ mem: [UInt8]) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        let n = mem.count
        while i < n {
            var j = i
            while j < n {
                var k = j
                while k < n && mem[k] == mem[j] { k += 1 }
                if k - j >= 6 { break }
                j = k
            }
            var k = j
            while k < n && k < j + 0xffff && mem[k] == mem[j] { k += 1 }
            tokens.append(Token(literal: j - i, fill: j < n ? mem[j] : 0, count: k - j))
            i = k
        }
        return tokens
    }
}

/// A complete VE.Bus device configuration as stored in a `.rvsc` file.
public struct DeviceConfiguration: Equatable, Sendable {
    public var formatVersion: String
    public var info: DeviceSettingInfo
    public var data: DeviceSettingData
    var mk2Version: UInt32
    var file: SettingFile

    public init(file: SettingFile) throws {
        guard let mk = file["Mk2vscInfo"], let infoBody = file["BareSettingInfo"], let dataBody = file["BareSettingData"]
        else { throw FormatError.badMagic("VE.Bus configuration (missing sections)") }
        var r = ByteReader(mk)
        mk2Version = try r.u32()
        formatVersion = try r.shortString()
        info = try DeviceSettingInfo(body: infoBody)
        data = try DeviceSettingData(body: dataBody)
        self.file = file
        // VE Configure asserts these match (docs/re/02-settings.md §2, §3). Info v<4 stores 3 firmware bytes.
        guard info.firmware & 0xFF_FFFF == data.firmware & 0xFF_FFFF else {
            throw FormatError.malformed("Setting info is for firmware \(info.firmware & 0xFF_FFFF) but the values are from firmware \(data.firmware & 0xFF_FFFF).")
        }
        guard info.configResponseChar == data.configResponseChar else {
            throw FormatError.malformed(String(format: "Setting info and values disagree on the device type (ConfigResponseChar 0x%02X vs 0x%02X).",
                                               info.configResponseChar, data.configResponseChar))
        }
        guard data.values.count >= info.records.count else {
            throw FormatError.malformed("The file has \(info.records.count) setting records but only \(data.values.count) values.")
        }
    }

    public init(contentsOf url: URL) throws {
        try self.init(file: try SettingFile(contentsOf: url))
    }

    public func settingFile() -> SettingFile {
        var f = file
        var w = ByteWriter()
        w.u32(mk2Version); w.shortString(formatVersion)
        f["Mk2vscInfo"] = w.data
        f["BareSettingInfo"] = info.encoded()
        f["BareSettingData"] = data.encoded()
        return f
    }

    public func encoded() -> [UInt8] { settingFile().encoded() }

    // MARK: Values

    public var firmware: Firmware { Firmware(number: data.firmware & 0xFF_FFFF) }

    public func raw(_ id: Int) -> UInt16 { data.values.indices.contains(id) ? data.values[id] : 0 }

    public mutating func setRaw(_ id: Int, _ value: UInt16) {
        guard data.values.indices.contains(id) else { return }
        data.values[id] = value
    }

    public func value(_ id: Int) -> Double? {
        guard let i = info.info(id), i.isSupported else { return nil }
        return i.display(raw(id))
    }

    /// Returns false (and changes nothing) for an unsupported setting or a non-finite value.
    @discardableResult
    public mutating func setValue(_ id: Int, _ value: Double) -> Bool {
        guard let r = info.info(id)?.rawValue(for: value), data.values.indices.contains(id) else { return false }
        setRaw(id, r)
        return true
    }

    static func isFlagIndex(_ n: Int) -> Bool { n >= 0 && n < SettingNames.flagWords.count * 16 }

    public func flag(_ n: Int) -> Bool {
        guard Self.isFlagIndex(n) else { return false }
        return raw(SettingNames.flagWords[n / 16]) >> UInt16(n % 16) & 1 == 1
    }

    public mutating func setFlag(_ n: Int, _ on: Bool) {
        guard Self.isFlagIndex(n) else { return }
        let word = SettingNames.flagWords[n / 16]
        let mask = UInt16(1) << UInt16(n % 16)
        setRaw(word, on ? raw(word) | mask : raw(word) & ~mask)
    }

    /// Whether the firmware supports flag bit `n` (the info record's max holds the supported-bits mask).
    public func supportsFlag(_ n: Int) -> Bool {
        guard Self.isFlagIndex(n), let i = info.info(SettingNames.flagWords[n / 16]), i.isSupported else { return false }
        return i.maxRaw >> UInt16(n % 16) & 1 == 1
    }

    public var serial: String? { data.serial }
    public var readDate: Date? { data.readTime > 0 ? Date(timeIntervalSince1970: TimeInterval(data.readTime)) : nil }
}

public struct Firmware: Equatable, Sendable, CustomStringConvertible {
    public var number: UInt32
    public var family: Int { Int(number / 100_000) }
    public var type: Int { Int(number % 100_000 / 1000) }
    public var version: Int { Int(number % 1000) }
    public var description: String { "\(number)" }
}
