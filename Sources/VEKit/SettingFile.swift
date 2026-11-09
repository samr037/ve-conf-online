import Foundation

/// A VE Configure "setting section file": `.rvsc` (Remote VE Configure, via GX/VRM) and `.vsc`.
///
/// Layout: `[u16 len]"VEConfig setting section file"`, then sections
/// `[u16 len][name][u32 absolute end offset][body][u32 checksum]`.
/// The checksum adds every byte shifted left by `8 * (i % 4)`,
/// from the section's name-length field up to the checksum itself.
public struct SettingFile: Equatable, Sendable {
    public static let magic = "VEConfig setting section file"

    public struct Section: Equatable, Sendable {
        public var name: String
        public var body: [UInt8]
        public init(name: String, body: [UInt8]) {
            self.name = name
            self.body = body
        }
    }

    public var sections: [Section]

    public init(sections: [Section]) {
        self.sections = sections
    }

    public subscript(name: String) -> [UInt8]? {
        get { sections.first { $0.name == name }?.body }
        set {
            if let i = sections.firstIndex(where: { $0.name == name }) {
                if let newValue { sections[i].body = newValue } else { sections.remove(at: i) }
            } else if let newValue {
                sections.append(Section(name: name, body: newValue))
            }
        }
    }

    public init(bytes: [UInt8]) throws {
        var r = ByteReader(bytes)
        guard (try? r.shortString()) == Self.magic else { throw FormatError.badMagic("VE Configure setting file") }
        var sections: [Section] = []
        while !r.isAtEnd {
            let start = r.offset
            let name = try r.shortString()
            let end = Int(try r.u32())
            guard end - 4 >= r.offset, end <= bytes.count else { throw FormatError.truncated(at: r.offset) }
            let body = try r.bytes(end - 4 - r.offset)
            let stored = try r.u32()
            guard stored == Self.checksum(bytes[start..<end - 4]) else { throw FormatError.badChecksum(section: name) }
            // Lookups take the first match by name; a second copy would be written back unedited.
            guard !sections.contains(where: { $0.name == name }) else { throw FormatError.duplicateSection(name) }
            sections.append(Section(name: name, body: body))
        }
        self.sections = sections
    }

    public init(contentsOf url: URL) throws {
        try self.init(bytes: [UInt8](try Data(contentsOf: url)))
    }

    public func encoded() -> [UInt8] {
        var w = ByteWriter()
        w.shortString(Self.magic)
        for section in sections {
            let start = w.data.count
            w.shortString(section.name)
            let endField = w.data.count
            w.u32(0)
            w.bytes(section.body)
            w.patchU32(at: endField, UInt32(w.data.count + 4))
            w.u32(Self.checksum(w.data[start...]))
        }
        return w.data
    }

    public func write(to url: URL) throws {
        try Data(encoded()).write(to: url, options: .atomic)
    }

    static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var sum: UInt32 = 0
        for (i, b) in bytes.enumerated() {
            sum &+= UInt32(b) << (8 * UInt32(i % 4))
        }
        return sum
    }
}
