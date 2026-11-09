import CryptoKit
import Foundation
import VEKit

// Golden fixtures for the TypeScript port (web/). The Swift implementation is the reference: these files record
// what it produces for every private sample and every assistant in the library, and the TypeScript tests must
// reproduce them byte for byte.
//
// Run:  swift run vegolden web/fixtures/golden
// The output derives from private samples and Victron's library: it stays out of Git (web/fixtures/.gitignore).

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let goldenOut = CommandLine.arguments.dropFirst().first ?? "web/fixtures/golden"
let libraryURL = root.appendingPathComponent("vendor/extracted/VE Configure tools/Assistants/all112.vfp")
func sampleURL(_ n: String) -> URL { root.appendingPathComponent("samples/\(n).rvsc") }
func sampleConfig(_ n: String) throws -> DeviceConfiguration { try DeviceConfiguration(contentsOf: sampleURL(n)) }
func assistantLibrary() throws -> AssistantLibrary { try AssistantLibrary(contentsOf: libraryURL) }

struct GoldenExport {
    static let samples = ["s1", "s2", "s3", "s4", "s5"]

    var out: URL {
        let u = URL(fileURLWithPath: goldenOut, relativeTo: root)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func samples() throws {
        let lib = try assistantLibrary()
        for name in Self.samples {
            let url = sampleURL(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let bytes = [UInt8](try Data(contentsOf: url))
            var doc: [String: Any] = ["name": name, "sha256": sha(bytes)]
            let file: SettingFile
            do { file = try SettingFile(bytes: bytes) } catch {
                doc["error"] = "\(error)"
                try write(doc, "samples/\(name).json")
                continue
            }
            doc["sections"] = file.sections.map { ["name": $0.name, "length": $0.body.count, "sha256": sha($0.body)] }
            doc["roundTrip"] = file.encoded() == bytes
            let c: DeviceConfiguration
            do { c = try DeviceConfiguration(file: file) } catch {
                doc["error"] = "\(error)"
                try write(doc, "samples/\(name).json")
                continue
            }
            doc["configRoundTrip"] = c.encoded() == bytes
            doc["encoded"] = hex(c.encoded())
            doc["formatVersion"] = c.formatVersion
            doc["info"] = info(c.info)
            doc["data"] = data(c.data)
            doc["firmware"] = ["number": c.firmware.number, "family": c.firmware.family, "type": c.firmware.type, "version": c.firmware.version]
            doc["settings"] = (0..<c.data.values.count).map { id -> [String: Any] in
                var s: [String: Any] = ["id": id, "name": SettingNames.settings.indices.contains(id) ? SettingNames.settings[id] : "",
                                        "raw": c.raw(id), "hidden": c.info.isHidden(setting: id), "protected": c.info.isProtected(setting: id)]
                if let v = c.value(id) { s["value"] = v }
                return s
            }
            doc["flags"] = (0..<SettingNames.flags.count).map { n -> [String: Any] in
                ["n": n, "name": SettingNames.flags[n], "on": c.flag(n), "supported": c.supportsFlag(n),
                 "hidden": c.info.isHidden(flag: n), "protected": c.info.isProtected(flag: n)]
            }
            let meta = MetaGenerator.source(for: c)
            doc["meta"] = String(meta.map { Character(Unicode.Scalar($0)) })
            doc["installedIDs"] = AssistantComposer.installedIDs(in: c.data.assistantMemory, library: lib)

            let composer = try AssistantComposer(library: lib)
            composer.meta = meta
            do {
                let r = try composer.reconstruct(image: c.data.assistantMemory)
                doc["reconstruct"] = result(r)
                doc["reconstructItems"] = composer.items.map(\.name)
                let b = composer.build()
                doc["rebuild"] = result(b)
                if b.success {
                    let (applied, battery) = try composer.apply(b, to: c)
                    doc["rebuildApplied"] = ["encoded": hex(applied.encoded()), "batteryType": battery as Any? ?? NSNull(),
                                             "identical": applied.encoded() == bytes]
                }
            } catch { doc["reconstructError"] = "\(error)" }
            try write(doc, "samples/\(name).json")
        }
    }

    func library() throws {
        let lib = try assistantLibrary()
        let doc: [String: Any] = [
            "sha256": sha([UInt8](try Data(contentsOf: libraryURL))),
            "packages": lib.packages.map { p -> [String: Any] in
                ["baseName": p.baseName, "id": p.id, "format": p.format, "flags": p.flags, "leading": hex(p.leading),
                 "entries": p.entries.map { ["name": $0.name, "dosTime": $0.dosTime, "attributes": $0.attributes,
                                             "length": $0.bytes.count, "sha256": sha($0.bytes)] }]
            },
            "latest": lib.latest.map(\.baseName),
        ]
        try write(doc, "library.json")
    }

    /// Each assistant added alone to s1 (no assistants) and to s5, wizard walked with the values shown.
    func wizardWalks() throws {
        let lib = try assistantLibrary()
        var index: [[String: Any]] = []
        for name in ["s1", "s5"] {
            guard FileManager.default.fileExists(atPath: sampleURL(name).path) else { continue }
            let c = try sampleConfig(name)
            let meta = MetaGenerator.source(for: c)
            for pkg in lib.latest where !pkg.baseName.lowercased().hasPrefix("asf") {
                let composer = try AssistantComposer(library: lib)
                composer.meta = meta
                composer.items = [.init(package: pkg)]
                var trail: [[String: Any]] = []
                var doc: [String: Any] = ["sample": name, "assistant": pkg.baseName, "id": pkg.id]
                let w = composer.wizard(for: pkg.baseName)
                loop: while trail.count < 300 {
                    switch w.status {
                    case .step(let p):
                        trail.append(presentation(p))
                        w.next(p.values)
                    case .finished(let r):
                        doc["outcome"] = "finished"
                        doc["result"] = result(r)
                        let b = composer.build()
                        doc["build"] = result(b)
                        if b.success, let (applied, battery) = try? composer.apply(b, to: c, extraChanges: r.vecChanges) {
                            doc["applied"] = ["encoded": hex(applied.encoded()), "batteryType": battery as Any? ?? NSNull()]
                        }
                        break loop
                    case .failed(let m):
                        doc["outcome"] = "failed"
                        doc["messages"] = m.map(message)
                        break loop
                    case .cancelled:
                        doc["outcome"] = "cancelled"
                        break loop
                    }
                }
                if doc["outcome"] == nil { doc["outcome"] = "limit" }
                doc["steps"] = trail
                let file = "walks/\(name)-\(slug(pkg.baseName)).json"
                try write(doc, file)
                index.append(["file": file, "sample": name, "assistant": pkg.baseName, "outcome": doc["outcome"]!, "steps": trail.count])
            }
        }
        try write(["walks": index], "walks/index.json")
    }

    // MARK: encoding

    func write(_ obj: Any, _ path: String) throws {
        let u = out.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let d = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try d.write(to: u)
    }

    func hex<C: Collection>(_ b: C) -> String where C.Element == UInt8 { b.map { String(format: "%02x", $0) }.joined() }
    func sha(_ b: [UInt8]) -> String { hex(Array(SHA256.hash(data: b))) }
    func slug(_ s: String) -> String { s.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined() }

    func info(_ i: DeviceSettingInfo) -> [String: Any] {
        ["version": i.version, "firmware": i.firmware, "configResponseChar": i.configResponseChar,
         "records": i.records.map { ["scaleRaw": $0.scaleRaw, "offset": $0.offset, "defaultRaw": $0.defaultRaw,
                                     "minRaw": $0.minRaw, "maxRaw": $0.maxRaw, "step": $0.step] },
         "flagAttributes": hex(i.flagAttributes), "settingAttributes": hex(i.settingAttributes),
         "gridTable": i.gridTable.map { hex($0) } ?? NSNull()]
    }

    func data(_ d: DeviceSettingData) -> [String: Any] {
        ["version": d.version, "deviceID": d.deviceID, "firmwareAlt": d.firmwareAlt, "obj20": d.obj20, "obj21": d.obj21,
         "byte8": d.byte8, "firmware": d.firmware, "firmwareExtra": hex(d.firmwareExtra), "configResponseChar": d.configResponseChar,
         "deviceRecord": hex(d.deviceRecord), "serial": d.serial ?? NSNull(), "tokens": d.tokens.map { hex($0) },
         "tokenTime": d.tokenTime, "readTime": d.readTime, "values": d.values, "assistantMemory": hex(d.assistantMemory)]
    }

    func value(_ v: Value) -> Any {
        switch v {
        case .int(let i): ["int": i]
        case .bool(let b): ["bool": b]
        case .string(let s): ["string": hex(s)]
        case .list(let l): ["list": l.map(value)]
        }
    }

    func message(_ m: AssemblerMessage) -> [String: Any] { ["kind": "\(m.kind)", "text": m.text, "position": m.position] }

    func step(_ s: AssistantStepDefinition) -> [String: Any] {
        ["id": s.id, "stepName": s.stepName, "kind": String(s.kind.rawValue), "inSummary": s.inSummary, "buttons": s.buttons,
         "fields": s.fields.map { f -> [String: Any] in
             let precision: Any = switch f.precision {
             case .decimals(let n): ["decimals": n]
             case .list: "list"
             case .time: "time"
             }
             return ["precision": precision, "unitCode": String(f.unitCode), "min": f.min, "max": f.max, "default": f.defaultValue]
         }]
    }

    func table(_ t: AnswerTable) -> [String: Any] {
        ["order": t.order,
         "answers": t.answers.mapValues { ["value": $0.value, "previous": $0.previous, "hasALD": $0.hasALD, "confirmed": $0.confirmed] },
         "steps": t.steps.mapValues(step)]
    }

    func presentation(_ p: AssistantStepPresentation) -> [String: Any] {
        ["assistant": p.assistant, "step": step(p.step), "labels": p.labels, "values": p.values,
         "format": p.format.map(value), "buttons": "\(p.buttons)", "isFirst": p.isFirst]
    }

    func result(_ r: AssistantBuildResult) -> [String: Any] {
        ["success": r.success, "cancelled": r.cancelled, "code": hex(r.code), "messages": r.messages.map(message),
         "answers": r.answers.mapValues(table), "vecChanges": r.vecChanges.mapValues(value),
         "steps": r.steps.map(presentation)]
    }
}

let g = GoldenExport()
let t0 = Date()
do {
    try g.library(); print("library ok")
    try g.samples(); print("samples ok")
    try g.wizardWalks(); print("walks ok")
} catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
print(String(format: "done in %.1fs → %@", Date().timeIntervalSince(t0), g.out.path))
