import Foundation
import zlib

public enum FormatError: Error, Equatable, CustomStringConvertible {
    case truncated(at: Int)
    case badMagic(String)
    case badChecksum(section: String)
    case decompression(String)
    case duplicateSection(String)
    case tooLarge(String, limit: Int)
    case unsupportedVersion(section: String, version: UInt32)
    case malformed(String)

    public var description: String {
        switch self {
        case .truncated(let at): "File ends unexpectedly at byte \(at)."
        case .badMagic(let what): "Not a \(what)."
        case .badChecksum(let name): "Section \(name) is corrupt (checksum mismatch)."
        case .decompression(let name): "Cannot decompress \(name)."
        case .duplicateSection(let name): "Section \(name) appears more than once; the file is ambiguous."
        case .tooLarge(let what, let limit): "\(what) is larger than \(limit) bytes."
        case .unsupportedVersion(let section, let version):
            "Section \(section) has version \(version), which this program does not know how to read."
        case .malformed(let why): why
        }
    }
}

/// Little-endian cursor over a byte buffer. All VE Configure files are little-endian (Delphi on x86).
struct ByteReader {
    let data: [UInt8]
    var offset: Int

    init(_ data: [UInt8], offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    var isAtEnd: Bool { offset >= data.count }
    var remaining: Int { data.count - offset }

    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= data.count else { throw FormatError.truncated(at: offset) }
        defer { offset += count }
        return Array(data[offset..<offset + count])
    }

    mutating func u8() throws -> UInt8 { try bytes(1)[0] }

    mutating func u16() throws -> UInt16 {
        let b = try bytes(2)
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        let b = try bytes(4)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    /// Delphi-style string: u16 length then Latin-1 bytes.
    mutating func shortString() throws -> String {
        let n = Int(try u16())
        return String(decoding: try bytes(n), as: Latin1.self)
    }
}

struct ByteWriter {
    var data: [UInt8] = []

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data += [UInt8(v & 0xff), UInt8(v >> 8)] }
    mutating func u32(_ v: UInt32) {
        data += [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24)]
    }
    mutating func bytes(_ b: [UInt8]) { data += b }
    mutating func shortString(_ s: String) {
        let b = Latin1.encode(s)
        u16(UInt16(b.count))
        data += b
    }
    mutating func patchU32(at index: Int, _ v: UInt32) {
        data[index] = UInt8(v & 0xff); data[index + 1] = UInt8(v >> 8 & 0xff)
        data[index + 2] = UInt8(v >> 16 & 0xff); data[index + 3] = UInt8(v >> 24)
    }
}

/// Latin-1 (Windows-1252 is close enough for the texts we see; assistants are written in ANSI).
enum Latin1: Unicode.Encoding {
    typealias CodeUnit = UInt8
    typealias EncodedScalar = CollectionOfOne<UInt8>
    static var encodedReplacementCharacter: EncodedScalar { CollectionOfOne(0x3f) }
    static func decode(_ content: EncodedScalar) -> Unicode.Scalar { Unicode.Scalar(content.first!) }
    static func encode(_ content: Unicode.Scalar) -> EncodedScalar? {
        content.value < 256 ? CollectionOfOne(UInt8(content.value)) : nil
    }
    struct Parser: Unicode.Parser {
        typealias Encoding = Latin1
        init() {}
        mutating func parseScalar<I: IteratorProtocol>(from input: inout I) -> Unicode.ParseResult<EncodedScalar>
        where I.Element == UInt8 {
            guard let b = input.next() else { return .emptyInput }
            return .valid(CollectionOfOne(b))
        }
    }
    typealias ForwardParser = Parser
    typealias ReverseParser = Parser

    static func encode(_ s: String) -> [UInt8] {
        s.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : 0x3f }
    }
}

/// Upper bound for one decompressed library entry. Real `.vap` files are a few hundred KB.
let inflateLimit = 16 << 20

func inflate(_ input: [UInt8], name: String, limit: Int = inflateLimit) throws -> [UInt8] {
    var stream = z_stream()
    guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        throw FormatError.decompression(name)
    }
    defer { inflateEnd(&stream) }
    var output = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 65536)
    var src = input
    var overflow = false
    let status: Int32 = src.withUnsafeMutableBufferPointer { inBuf in
        stream.next_in = inBuf.baseAddress
        stream.avail_in = uInt(inBuf.count)
        var status: Int32 = Z_OK
        repeat {
            status = chunk.withUnsafeMutableBufferPointer { outBuf in
                stream.next_out = outBuf.baseAddress
                stream.avail_out = uInt(outBuf.count)
                return zlib.inflate(&stream, Z_NO_FLUSH)
            }
            output += chunk[0..<(chunk.count - Int(stream.avail_out))]
            if output.count > limit { overflow = true; break }
        } while status == Z_OK
        return status
    }
    if overflow { throw FormatError.tooLarge("Decompressed \(name)", limit: limit) }
    guard status == Z_STREAM_END else { throw FormatError.decompression(name) }
    return output
}
