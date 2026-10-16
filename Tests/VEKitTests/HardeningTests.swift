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
}
