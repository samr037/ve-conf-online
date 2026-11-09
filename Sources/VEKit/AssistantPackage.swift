import Foundation

/// One Assistant as shipped by Victron (`.vap`): wizard scripts per language plus the `.vll` source.
///
/// Layout: 4 bytes (unknown, `31 20 57 f6`), `[u16 len]"Victron Energy Assistant Package"`,
/// u32 format (1), u32 assistant id, u32 (1), then entries `[u16 len][name][u32 DOS time][u32 attr][u32 size][bytes]`.
public struct AssistantPackage: Sendable, Identifiable {
    public static let magic = "Victron Energy Assistant Package"

    public struct Entry: Sendable {
        public var name: String
        public var dosTime: UInt32
        public var attributes: UInt32
        public var bytes: [UInt8]
        public var text: String { String(decoding: bytes, as: Latin1.self) }
    }

    public var leading: [UInt8]
    public var format: UInt32
    public var id: UInt32
    public var flags: UInt32
    public var entries: [Entry]

    /// File name in the pack without the `_XXXX` id suffix, e.g. "ESS".
    public var baseName: String

    public init(bytes: [UInt8], fileName: String = "") throws {
        var r = ByteReader(bytes)
        leading = try r.bytes(4)
        guard try r.shortString() == Self.magic else { throw FormatError.badMagic("Victron assistant package") }
        format = try r.u32()
        id = try r.u32()
        flags = try r.u32()
        var entries: [Entry] = []
        while r.remaining >= 2 {
            let name = try r.shortString()
            let time = try r.u32()
            let attr = try r.u32()
            let size = Int(try r.u32())
            entries.append(Entry(name: name, dosTime: time, attributes: attr, bytes: try r.bytes(size)))
        }
        self.entries = entries
        var base = (fileName as NSString).deletingPathExtension
        if let underscore = base.lastIndex(of: "_") { base = String(base[..<underscore]) }
        baseName = base
    }

    /// The assembler source.
    public var source: Entry? { entries.first { $0.name.lowercased().hasSuffix(".vll") } }

    /// Wizard scripts keyed by language extension ("en", "fr", "de", ...).
    public var scripts: [String: Entry] {
        var out: [String: Entry] = [:]
        for e in entries where !e.name.lowercased().hasSuffix(".vll") {
            out[(e.name as NSString).pathExtension.lowercased()] = e
        }
        return out
    }

    public func script(preferring languages: [String]) -> Entry? {
        let all = scripts
        for lang in languages + ["en"] { if let s = all[lang] { return s } }
        return all.values.first
    }
}

/// The assistant library (`allNNN.vfp`): a flat list of zlib-compressed `.vap` files.
///
/// Entry layout: `[u16 len][name][u32 DOS time][u32 attr][u32 compressed size][zlib bytes]`.
public struct AssistantLibrary: Sendable {
    public var packages: [AssistantPackage]

    public init(bytes: [UInt8]) throws {
        var r = ByteReader(bytes)
        var packages: [AssistantPackage] = []
        while r.remaining >= 2 {
            let name = try r.shortString()
            _ = try r.u32()
            _ = try r.u32()
            let size = Int(try r.u32())
            let raw = try r.bytes(size)
            packages.append(try AssistantPackage(bytes: try inflate(raw, name: name), fileName: name))
        }
        self.packages = packages
    }

    public init(contentsOf url: URL) throws {
        try self.init(bytes: [UInt8](try Data(contentsOf: url)))
    }

    /// Latest package for each assistant name.
    public var latest: [AssistantPackage] {
        Dictionary(grouping: packages, by: \.baseName)
            .compactMap { $0.value.max { $0.id < $1.id } }
            .sorted { $0.baseName.localizedCaseInsensitiveCompare($1.baseName) == .orderedAscending }
    }

    public func package(id: UInt32) -> AssistantPackage? { packages.first { $0.id == id } }
}
