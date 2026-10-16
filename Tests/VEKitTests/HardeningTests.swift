import Foundation
import Testing
import zlib
@testable import VEKit

/// Regression tests for the 2026-10-16 audit (docs/audit/2026-10-16.md): crafted files must be refused
/// with a clear error instead of being misread, truncated or written back half-edited.
enum Crafted {
    static func file(_ sample: String = "s2.rvsc") throws -> SettingFile {
        try SettingFile(contentsOf: Fixtures.sample(sample))
    }

    /// `BareSettingData` split into the part before the values blob, the values bytes and the RLE stream.
    static func dataParts(_ body: [UInt8]) throws -> (head: [UInt8], values: [UInt8], rle: [UInt8]) {
        var r = ByteReader(body)
        let version = try r.u32()
        _ = try r.bytes(8)
        if version >= 3 { _ = try r.bytes(2) }
        _ = try r.bytes(5)
        _ = try r.bytes(Int(try r.u16()))
        _ = try r.bytes(10)
        if version > 1 {
            _ = try r.shortString()
            for _ in 0..<Int(try r.u16()) { _ = try r.bytes(Int(try r.u16())) }
            _ = try r.bytes(16)
        }
        let head = Array(body[..<r.offset])
        let values = try r.bytes(Int(try r.u16()))
        return (head, values, try r.bytes(r.remaining))
    }

    static func dataBody(head: [UInt8], values: [UInt8], rle: [UInt8]) -> [UInt8] {
        var w = ByteWriter()
        w.bytes(head); w.u16(UInt16(values.count)); w.bytes(values); w.bytes(rle)
        return w.data
    }

    /// Sample with its `BareSettingData` rebuilt from modified parts; checksums stay valid.
    static func withData(_ sample: String = "s2.rvsc",
                         _ edit: (inout [UInt8], inout [UInt8], inout [UInt8]) -> Void) throws -> [UInt8] {
        var f = try file(sample)
        var (h, v, r) = try dataParts(f["BareSettingData"]!)
        edit(&h, &v, &r)
        f["BareSettingData"] = dataBody(head: h, values: v, rle: r)
        return f.encoded()
    }

    static func withInfo(_ sample: String = "s2.rvsc", _ edit: (inout [UInt8]) -> Void) throws -> [UInt8] {
        var f = try file(sample)
        var body = f["BareSettingInfo"]!
        edit(&body)
        f["BareSettingInfo"] = body
        return f.encoded()
    }

    static func load(_ bytes: [UInt8]) throws -> DeviceConfiguration {
        try DeviceConfiguration(file: try SettingFile(bytes: bytes))
    }
}

@Suite struct HardeningTests {
    // MARK: Container

    @Test func allSamplesStillRoundTrip() throws {
        for name in ["s1.rvsc", "s2.rvsc", "s3.rvsc", "s4.rvsc", "s5.rvsc"] {
            let bytes = [UInt8](try Data(contentsOf: Fixtures.sample(name)))
            #expect(try Crafted.load(bytes).encoded() == bytes, "\(name)")
        }
    }

    /// Audit #12: a second `BareSettingData` was kept and written back unedited (only the first one is edited).
    @Test func duplicateSectionIsRejected() throws {
        var f = try Crafted.file()
        f.sections.append(f.sections[2])
        #expect(throws: FormatError.duplicateSection("BareSettingData")) { try SettingFile(bytes: f.encoded()) }
    }

    /// Audit #36: inflate had no output limit (3 MB of zlib → 6 GB).
    @Test func inflateIsBounded() throws {
        func deflate(_ input: [UInt8]) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: Int(compressBound(uLong(input.count))))
            var n = uLongf(out.count)
            #expect(compress2(&out, &n, input, uLong(input.count), 9) == Z_OK)
            return Array(out[..<Int(n)])
        }
        let small = deflate([UInt8](repeating: 7, count: 1000))
        #expect(try inflate(small, name: "x") == [UInt8](repeating: 7, count: 1000))
        #expect(throws: FormatError.tooLarge("Decompressed x", limit: 100)) { try inflate(small, name: "x", limit: 100) }
        let bomb = deflate([UInt8](repeating: 0, count: inflateLimit + 1))
        #expect(throws: FormatError.self) { try inflate(bomb, name: "bomb") }
    }

    // MARK: Assistant memory (RLE)

    /// Audit #35: 104 KB of RLE tokens decoded to 2.6 GB.
    @Test func rleBombIsRejected() throws {
        let bytes = try Crafted.withData { _, _, r in r = Array([UInt8]([0, 0, 0xFF, 0xFF, 0xFF]).repeated(20000)) }
        #expect(throws: FormatError.tooLarge("Assistant memory", limit: 4096)) { try Crafted.load(bytes) }
        #expect(throws: FormatError.self) { try RLE.decode([0, 0, 0xFF, 0x01, 0x10]) }   // 4097 bytes
    }

    /// Audit #3: a short image was accepted and later written back truncated or overwritten.
    @Test(arguments: [[UInt8](), [0, 0, 0xFF, 0x64, 0x00]])
    func assistantMemoryMustBe4096Bytes(rle: [UInt8]) throws {
        let bytes = try Crafted.withData { _, _, r in r = rle }
        #expect(throws: FormatError.self) { try Crafted.load(bytes) }
    }

    // MARK: Values and records

    /// Audit #37: more than 192 values crashed `vecfg show`. VE Configure reads 0x180 bytes and skips the rest.
    @Test func excessValuesAreCappedAt192() throws {
        let bytes = try Crafted.withData { _, v, _ in v += [UInt8](repeating: 0, count: 2 * (400 - 192)) }
        let c = try Crafted.load(bytes)
        #expect(c.data.values.count == 192)
        let original = try DeviceConfiguration(contentsOf: Fixtures.sample("s2.rvsc"))
        #expect(c.data.values == original.data.values)
        #expect(c.encoded() == original.encoded())
    }

    @Test func oddValuesBlobIsRejected() throws {
        let bytes = try Crafted.withData { _, v, _ in v.append(7) }
        #expect(throws: FormatError.self) { try Crafted.load(bytes) }
    }

    @Test func recordsBlobMustBeWholeRecords() throws {
        let bytes = try Crafted.withInfo { b in
            let n = Int(b[9]) | Int(b[10]) << 8
            b = Array(b[..<9]) + [UInt8((n + 3) & 0xFF), UInt8((n + 3) >> 8)] + Array(b[11..<(11 + n)]) + [1, 2, 3] + Array(b[(11 + n)...])
        }
        #expect(throws: FormatError.self) { try Crafted.load(bytes) }
    }

    /// Audit #18: with fewer values than records, writes to the missing ids were dropped silently.
    @Test func fewerValuesThanRecordsIsRejected() throws {
        let bytes = try Crafted.withData { _, v, _ in v = Array(v.prefix(100)) }
        #expect(throws: FormatError.malformed("The file has 192 setting records but only 50 values.")) { try Crafted.load(bytes) }
    }

    @Test func unknownSectionVersionsAreRejected() throws {
        let info5 = try Crafted.withInfo { b in b[0] = 5 }
        #expect(throws: FormatError.unsupportedVersion(section: "BareSettingInfo", version: 5)) { try Crafted.load(info5) }
        let data4 = try Crafted.withData { h, _, _ in h[0] = 4 }
        #expect(throws: FormatError.unsupportedVersion(section: "BareSettingData", version: 4)) { try Crafted.load(data4) }
    }

    // MARK: Info vs Data consistency (audit #17)

    @Test func firmwareMismatchIsRejected() throws {
        let bytes = try Crafted.withInfo { b in b[4] ^= 0x01 }
        #expect(throws: FormatError.self) { try Crafted.load(bytes) }
    }

    @Test func configResponseCharMismatchIsRejected() throws {
        let bytes = try Crafted.withInfo { b in b[8] ^= 0x01 }
        #expect(throws: FormatError.self) { try Crafted.load(bytes) }
    }

    // MARK: Accessors

    @Test func negativeAndOutOfRangeIdsAreHarmless() throws {
        var c = try DeviceConfiguration(contentsOf: Fixtures.sample("s5.rvsc"))
        let before = c.encoded()
        #expect(c.info.info(-1) == nil)
        #expect(c.raw(-1) == 0)
        #expect(c.value(-1) == nil)
        c.setRaw(-1, 1); c.setRaw(192, 1)
        let setNegative = c.setValue(-1, 1)
        #expect(!setNegative)
        #expect(!c.flag(-1) && !c.flag(80) && !c.supportsFlag(-1) && !c.supportsFlag(80))
        c.setFlag(-1, true); c.setFlag(80, true)
        #expect(!c.info.isHidden(setting: -1))
        #expect(c.encoded() == before)
    }

    @Test func nonFiniteValuesAreRefused() throws {
        var c = try DeviceConfiguration(contentsOf: Fixtures.sample("s5.rvsc"))
        let info = try #require(c.info.info(2))
        for v in [Double.nan, .infinity, -.infinity] {
            #expect(info.rawValue(for: v) == nil)
            let accepted = c.setValue(2, v)
            #expect(!accepted)
        }
        #expect(c.value(2) == 52.0)
    }

    /// Delphi `Round` (VE Configure) is banker's rounding; the CLI must agree with the GUI.
    @Test func roundingIsHalfToEven() {
        let unit = SettingInfo(scaleRaw: 1, offset: 0, defaultRaw: 0, minRaw: 0, maxRaw: 100)
        #expect(unit.rawValue(for: 2.5) == 2)
        #expect(unit.rawValue(for: 3.5) == 4)
        #expect(unit.rawValue(for: 2.4) == 2)
        let half = SettingInfo(scaleRaw: 2, offset: 0, defaultRaw: 0, minRaw: 0, maxRaw: 100)
        #expect(half.rawValue(for: 5) == 2)
        #expect(half.rawValue(for: 7) == 4)
    }

    // MARK: Protection (audit #13)

    @Test func gridSettingsAreProtectedWithoutAttributeBytes() throws {
        var c = try DeviceConfiguration(contentsOf: Fixtures.sample("s5.rvsc"))
        #expect(c.info.isProtected(setting: 81))
        c.info.settingAttributes = []
        c.info.flagAttributes = []
        #expect(c.info.isProtected(setting: 81))
        #expect((128...191).allSatisfy { c.info.isProtected(setting: $0) })
        #expect(!c.info.isProtected(setting: 2))
        #expect(c.info.isProtected(flag: 64))
        #expect(!c.info.isProtected(flag: 5))

        // A version-1 info section has no attribute bytes at all.
        let v1 = try Crafted.withInfo("s5.rvsc") { b in
            let n = Int(b[9]) | Int(b[10]) << 8
            b = [1, 0, 0, 0] + Array(b[4..<(11 + n)])
        }
        let old = try Crafted.load(v1)
        #expect(old.info.settingAttributes.isEmpty)
        #expect(old.info.isProtected(setting: 81) && old.info.isProtected(setting: 140))
    }
}

extension Array {
    func repeated(_ n: Int) -> [Element] { Array((0..<n).map { _ in self }.joined()) }
}
