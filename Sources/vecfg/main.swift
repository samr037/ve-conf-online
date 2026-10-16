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

func diff(_ a: String, _ b: String) {
    let x = load(a), y = load(b)
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

func set(_ args: [String]) {
    guard let path = args.first, let o = args.firstIndex(of: "-o"), o + 1 < args.count else { fail(usage) }
    var c = load(path)
    for assignment in args[1..<o] {
        let parts = assignment.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { fail("expected NAME=VALUE, got \(assignment)") }
        let key = parts[0], value = parts[1]
        let match: (String) -> Bool = { displayName($0).lowercased() == key.lowercased() || $0 == key }
        if let n = SettingNames.flags.firstIndex(where: match) {
            guard c.supportsFlag(n) else { fail("\(key) is not supported by this firmware") }
            c.setFlag(n, ["1", "on", "true", "yes"].contains(value.lowercased()))
        } else if let id = Int(key) ?? SettingNames.settings.firstIndex(where: match) {
            guard let v = Double(value) else { fail("\(key): not a number: \(value)") }
            guard c.info.info(id)?.isSupported == true else { fail("\(key) is not supported by this device") }
            if c.info.isProtected(setting: id) { fail("\(key) is protected (grid code password) — not editable here") }
            c.setValue(id, v)
            if abs((c.value(id) ?? v) - v) > 1e-9 { print("  note: \(key) set to \(format(c, id)) (device step/range)") }
        } else {
            fail("unknown setting or flag: \(key)")
        }
    }
    do { try c.settingFile().write(to: URL(fileURLWithPath: args[o + 1])) } catch { fail("\(error)") }
    diff(path, args[o + 1])
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
case "install" where args.count >= 5:
    // vecfg install <vfp> <target.rvsc> <answers-from.rvsc> -o <out.rvsc>: replay another file's assistants onto a target.
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
        let (out, battery) = composer.apply(r, to: target)
        if let battery { print("  note: assistants selected battery preset \(battery)") }
        guard let o = args.firstIndex(of: "-o"), o + 1 < args.count else { fail(usage) }
        try out.settingFile().write(to: URL(fileURLWithPath: args[o + 1]))
        print("  assistant settings changes: " + r.vecChanges.keys.sorted().joined(separator: ", "))
        diff(args[1], args[o + 1])
    } catch { fail("\(error)") }
case "meta" where !args.isEmpty: print(MetaGenerator.lines(for: load(args[0])).joined(separator: "\n"))
default: fail(usage)
}
