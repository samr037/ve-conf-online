import Foundation
import VEKit

// vecfg — inspect, compare and edit VE Configure setting files (.rvsc / .vsc) without Windows.
//   vecfg show <file> [--all]
//   vecfg diff <a> <b>
//   vecfg set <file> <name|id>=<value>... -o <out>
//   vecfg assistants <allNNN.vfp>

let usage = """
usage:
  vecfg show <file.rvsc> [--all]          settings, flags and assistant memory summary
  vecfg diff <a.rvsc> <b.rvsc>            what differs between two configurations
  vecfg set <file.rvsc> NAME=VALUE... -o <out.rvsc>
                                          change settings (physical units) or flags (on/off)
  vecfg assistants <allNNN.vfp>           list the assistants in a Victron library
  vecfg reconstruct <allNNN.vfp> <file.rvsc> [--meta META.vll] [--all]
                                          recover assistant answers from the device program
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func load(_ path: String) -> DeviceConfiguration {
    do { return try DeviceConfiguration(contentsOf: URL(fileURLWithPath: path)) } catch { fail("\(path): \(error)") }
}

func displayName(_ name: String) -> String {
    var n = name
    if n.hasPrefix("@") { n.removeFirst() }
    if n.hasPrefix("_") { n.removeFirst() }
    for p in ["eest", "eecv", "eevs", "eefs", "ee"] where n.hasPrefix(p) { return String(n.dropFirst(p.count)) }
    return n
}

func pad(_ v: Any, _ width: Int) -> String {
    let s = "\(v)"
    return String(repeating: " ", count: max(0, width - s.count)) + s
}

func format(_ c: DeviceConfiguration, _ id: Int) -> String {
    guard let v = c.value(id) else { return "—" }
    if [0, 1, 60, 61, 82].contains(id) { return String(format: "0x%04X", c.raw(id)) }
    if id == 81 { return SettingNames.gridCodes.indices.contains(Int(c.raw(id))) ? SettingNames.gridCodes[Int(c.raw(id))] : "\(c.raw(id))" }
    let step = c.info.info(id)?.step ?? 1
    let decimals = step >= 1 ? 0 : step >= 0.1 ? 1 : step >= 0.01 ? 2 : 3
    return String(format: "%.\(decimals)f", v)
}

func show(_ path: String, all: Bool) {
    let c = load(path)
    print("\(path)")
    print("  serial \(c.serial ?? "?")  firmware \(c.firmware)  read \(c.readDate.map { ISO8601DateFormatter().string(from: $0) } ?? "?")")
    for id in 0..<c.data.values.count {
        let name = SettingNames.settings[id]
        guard let info = c.info.info(id), info.isSupported else { continue }
        if !all && (name.hasPrefix("@") || id >= 128) { continue }
        let changed = c.raw(id) != info.defaultRaw ? "*" : " "
        let range = String(format: "[%g … %g, default %g]", info.display(info.minRaw), info.display(info.maxRaw), info.display(info.defaultRaw))
        print("  \(pad(id, 3)) \(changed) \(displayName(name).padding(toLength: 30, withPad: " ", startingAt: 0)) \(pad(format(c, id), 10))  \(range)")
    }
    let on = (0..<SettingNames.flags.count).filter { c.supportsFlag($0) && c.flag($0) }.map { displayName(SettingNames.flags[$0]) }
    print("  flags on: \(on.joined(separator: ", "))")
    let mem = c.data.assistantMemory
    let code = mem.firstIndex(of: 0xFF).map { i in mem[i...].starts(with: repeatElement(0xFF, count: 16)) ? i : mem.count } ?? mem.count
    print("  assistant program: \(mem.allSatisfy { $0 == 0xFF } ? "empty" : "\(code) bytes of code in \(mem.count) bytes of memory")")
}

func diff(_ a: String, _ b: String) { diff(load(a), load(b)) }

func diff(_ x: DeviceConfiguration, _ y: DeviceConfiguration) {
    var any = false
    for id in 0..<min(x.data.values.count, y.data.values.count) where x.raw(id) != y.raw(id) {
        if [0, 1, 60, 61, 82].contains(id) { continue }
        any = true
        print("  \(pad(id, 3)) \(displayName(SettingNames.settings[id]).padding(toLength: 30, withPad: " ", startingAt: 0)) \(pad(format(x, id), 10)) → \(format(y, id))")
    }
    for n in 0..<SettingNames.flags.count where x.flag(n) != y.flag(n) {
        any = true
        print("      flag \(displayName(SettingNames.flags[n])): \(x.flag(n) ? "on" : "off") → \(y.flag(n) ? "on" : "off")")
    }
    if x.data.assistantMemory != y.data.assistantMemory { any = true; print("      assistant program differs") }
    if !any { print("  identical settings") }
}

/// Whether two paths name the same file: after `.`/`..`/symlink resolution, or the same inode (hard link,
/// case-insensitive volume).
func samePath(_ a: String, _ b: String) -> Bool {
    let x = URL(fileURLWithPath: a).standardizedFileURL.resolvingSymlinksInPath().path
    let y = URL(fileURLWithPath: b).standardizedFileURL.resolvingSymlinksInPath().path
    if x == y { return true }
    guard let ax = try? FileManager.default.attributesOfItem(atPath: x),
          let ay = try? FileManager.default.attributesOfItem(atPath: y) else { return false }
    func id(_ attrs: [FileAttributeKey: Any]) -> [NSNumber?] {
        [attrs[.systemNumber] as? NSNumber, attrs[.systemFileNumber] as? NSNumber]
    }
    return id(ax)[0] != nil && id(ax)[1] != nil && id(ax) == id(ay)
}

/// `-o <out>` must be the last two arguments and must not overwrite any input.
func outputPath(_ args: [String], inputs: [String], minIndex: Int) -> String {
    guard let o = args.firstIndex(of: "-o"), o >= minIndex, o + 2 == args.count else {
        fail("-o <out.rvsc> is required and must come last\n" + usage)
    }
    let out = args[o + 1]
    for input in inputs where samePath(input, out) { fail("refusing to overwrite the input \(input); choose another -o") }
    return out
}

func parseFlag(_ value: String) -> Bool? {
    switch value.lowercased() {
    case "1", "on", "true", "yes": true
    case "0", "off", "false", "no": false
    default: nil
    }
}

/// Write `c` to `out`, read it back and list what changed against the in-memory original.
func writeAndDiff(_ c: DeviceConfiguration, to out: String, original: DeviceConfiguration) {
    do { try c.settingFile().write(to: URL(fileURLWithPath: out)) } catch { fail("\(out): \(error)") }
    let reread = load(out)
    guard reread.encoded() == c.encoded() else { fail("\(out): written file does not read back identically") }
    diff(original, reread)
}

func set(_ args: [String]) {
    guard let path = args.first, path != "-o" else { fail(usage) }
    let out = outputPath(args, inputs: [path], minIndex: 1)
    let original = load(path)
    var c = original
    for assignment in args[1..<(args.count - 2)] {
        let parts = assignment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else { fail("expected NAME=VALUE, got \(assignment)") }
        let key = parts[0], value = parts[1]
        let match: (String) -> Bool = { displayName($0).lowercased() == key.lowercased() || $0 == key }
        if let n = SettingNames.flags.firstIndex(where: match) {
            guard c.supportsFlag(n) else { fail("\(key) is not supported by this firmware") }
            if c.info.isProtected(flag: n) { fail("\(key) is protected (grid code password) — not editable here") }
            guard let on = parseFlag(value) else { fail("\(key): expected on/off, 1/0, true/false or yes/no, got \(value)") }
            c.setFlag(n, on)
        } else if let id = Int(key) ?? SettingNames.settings.firstIndex(where: match) {
            guard SettingNames.settings.indices.contains(id) else { fail("\(key): no such setting id (0…\(SettingNames.settings.count - 1))") }
            if SettingNames.flagWords.contains(id) { fail("\(key) is a whole flag word; set its flags by name instead") }
            guard let v = Double(value), v.isFinite else { fail("\(key): not a number: \(value)") }
            guard c.info.info(id)?.isSupported == true else { fail("\(key) is not supported by this device") }
            if c.info.isProtected(setting: id) { fail("\(key) is protected (grid code password) — not editable here") }
            guard c.setValue(id, v) else { fail("\(key): cannot store \(value)") }
            if abs((c.value(id) ?? v) - v) > 1e-9 { print("  note: \(key) set to \(format(c, id)) (device step/range)") }
        } else {
            fail("unknown setting or flag: \(key)")
        }
    }
    writeAndDiff(c, to: out, original: original)
}

func assistants(_ path: String) {
    do {
        let lib = try AssistantLibrary(contentsOf: URL(fileURLWithPath: path))
        for p in lib.latest {
            let langs = p.scripts.keys.sorted().joined(separator: ",")
            print("  " + String(format: "0x%04X", p.id) + "  " + p.baseName.padding(toLength: 40, withPad: " ", startingAt: 0) + langs)
        }
        print("  \(lib.packages.count) packages, \(lib.latest.count) assistants")
    } catch { fail("\(path): \(error)") }
}

func reconstruct(_ args: [String]) {
    guard args.count >= 2 else { fail(usage) }
    let c = load(args[1])
    if AssistantComposer.installedIDs(in: c.data.assistantMemory).count < 2 {
        print("  no assistants installed")
        return
    }
    do {
        let lib = try AssistantLibrary(contentsOf: URL(fileURLWithPath: args[0]))
        let composer = try AssistantComposer(library: lib)
        if let i = args.firstIndex(of: "--meta"), i + 1 < args.count {
            composer.meta = [UInt8](try Data(contentsOf: URL(fileURLWithPath: args[i + 1])))
        } else {
            composer.meta = MetaGenerator.source(for: c)
        }
        let r = try composer.reconstruct(image: c.data.assistantMemory)
        print("  assistants: " + ([composer.framework.start] + composer.items.map(\.package) + [composer.framework.stop])
            .map { String(format: "%@_%04X", $0.baseName, $0.id) }.joined(separator: " + "))
        print("  \(r.success ? "OK" : "FAILED") — \(r.code.count) bytes of code")
        for m in r.messages.prefix(args.contains("--all") ? 1000 : 15) { print("  \(m)") }
        if r.success {
            for (name, table) in r.answers.sorted(by: { $0.key < $1.key }) where !table.answers.isEmpty {
                print("  \(name): " + table.answers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.value)" }.joined(separator: " "))
            }
            // Cold rebuild from the recovered answers only (no device binary), then the full image.
            let b = composer.build()
            let image = composer.image(code: b.code, size: c.data.assistantMemory.count)
            let same = image == c.data.assistantMemory
            print("  rebuild from answers: \(b.success ? "OK" : "FAILED"), \(b.code.count) bytes; full image \(same ? "IDENTICAL to the device" : "DIFFERS")")
            if !same, let d = zip(image, c.data.assistantMemory).enumerated().first(where: { $0.element.0 != $0.element.1 }) {
                print(String(format: "  first difference at 0x%03X: %02X vs device %02X", d.offset, d.element.0, d.element.1))
            }
        }
    } catch { fail("\(error)") }
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usage) }
args.removeFirst()
switch command {
case "show" where !args.isEmpty: show(args[0], all: args.contains("--all"))
case "diff" where args.count == 2: diff(args[0], args[1])
case "set": set(args)
case "assistants" where !args.isEmpty: assistants(args[0])
case "reconstruct": reconstruct(args)
case "wizard" where args.count >= 3:
    // vecfg wizard <vfp> <file.rvsc> <Assistant>: walk the assistant's steps, answering Next with the current values.
    do {
        let lib = try AssistantLibrary(contentsOf: URL(fileURLWithPath: args[0]))
        let c = load(args[1])
        let composer = try AssistantComposer(library: lib)
        composer.meta = MetaGenerator.source(for: c)
        _ = try composer.reconstruct(image: c.data.assistantMemory)
        let w = composer.wizard(for: args[2])
        var n = 0
        loop: while true {
            switch w.status {
            case .step(let p):
                n += 1
                let pkg = composer.items.first { $0.name == p.assistant }?.package
                let text = pkg?.script(preferring: ["en"]).map { WizardText($0.bytes) }
                let content = WizardStepContent(step: p.step, text: text, format: p.format)
                let values = zip(p.step.fields, p.values).map { $0.display($1) }.joined(separator: ", ")
                print("  \(n). [\(p.step.kind.rawValue)] \(content.title) — \(p.labels.joined(separator: ",")) = \(values)")
                if n > 200 { print("  too many steps"); break loop }
                var answer = p.values
                for a in args.dropFirst(3) where a.contains("=") {
                    let kv = a.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    guard kv.count == 2, !kv[0].isEmpty else { fail("expected LABEL=VALUE, got \(a)") }
                    guard let i = p.labels.firstIndex(of: kv[0]) else { continue }
                    guard i < answer.count else { fail("\(kv[0]): this step has no value slot for it") }
                    guard let v = Int32(kv[1]) else { fail("\(kv[0]): not a 32-bit integer: \(kv[1])") }
                    answer[i] = v
                    print("     → \(kv[0]) = \(v)")
                }
                w.next(answer)
            case .finished(let r):
                let img = composer.image(code: r.code, size: c.data.assistantMemory.count)
                print("  finished after \(n) steps; image \(img == c.data.assistantMemory ? "IDENTICAL to the device" : "differs"); settings changed: \(r.vecChanges.keys.sorted())")
                break loop
            case .failed(let m): print("  failed: \(m.prefix(5))"); break loop
            case .cancelled: print("  cancelled"); break loop
            }
        }
    } catch { fail("\(error)") }
case "install" where args.count >= 5:
    // vecfg install <vfp> <target.rvsc> <answers-from.rvsc> -o <out.rvsc>: replay another file's assistants onto a target.
    let outPath = outputPath(args, inputs: [args[0], args[1], args[2]], minIndex: 3)
    do {
        let lib = try AssistantLibrary(contentsOf: URL(fileURLWithPath: args[0]))
        let target = load(args[1]), source = load(args[2])
        let donor = try AssistantComposer(library: lib)
        donor.meta = MetaGenerator.source(for: source)
        let r0 = try donor.reconstruct(image: source.data.assistantMemory)
        guard r0.success else { fail("cannot reconstruct \(args[2]): \(r0.messages)") }
        let composer = try AssistantComposer(library: lib)
        composer.items = donor.items
        composer.framework = donor.framework
        composer.answers = donor.answers
        composer.meta = MetaGenerator.source(for: target)
        let r = composer.build()
        guard r.success else { fail("build failed: \(r.messages.prefix(5))") }
        // Code + one u16 per assistant ID (asfStart, assistants, asfStop) + u32 checksum must fit the memory.
        let ids = [composer.framework.start.id] + composer.items.map(\.package.id) + [composer.framework.stop.id]
        let size = target.data.assistantMemory.count
        let needed = r.code.count + 2 * ids.count + 4
        guard needed <= size else {
            fail("assistant program does not fit: \(r.code.count) bytes of code + \(ids.count) IDs + checksum = \(needed) > \(size) bytes")
        }
        let (out, battery) = composer.apply(r, to: target)
        let mem = out.data.assistantMemory
        guard mem.count == size, Array(mem.prefix(r.code.count)) == r.code,
              AssistantComposer.installedIDs(in: mem) == ids else {
            fail("internal error: the assistant image does not hold the built code and IDs; nothing written")
        }
        if let battery { print("  note: assistants selected battery preset \(battery)") }
        print("  assistant settings changes: " + r.vecChanges.keys.sorted().joined(separator: ", "))
        writeAndDiff(out, to: outPath, original: target)
    } catch { fail("\(error)") }
case "meta" where !args.isEmpty: print(MetaGenerator.lines(for: load(args[0])).joined(separator: "\n"))
default: fail(usage)
}
