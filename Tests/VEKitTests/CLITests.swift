import Foundation
import Testing
@testable import VEKit

/// Runs the built `vecfg` (same products directory as the test bundle).
enum CLI {
    static let binary: URL? = {
        // swift test runs the tests from a .xctest bundle in the products directory; vecfg sits beside it.
        var candidates = (Bundle.allBundles + [Bundle.main]).map(\.bundleURL)
        candidates += CommandLine.arguments.map { URL(fileURLWithPath: $0) }
        for c in candidates {
            var dir = c
            for _ in 0..<5 {
                dir = dir.deletingLastPathComponent()
                let url = dir.appendingPathComponent("vecfg")
                if FileManager.default.isExecutableFile(atPath: url.path) { return url }
            }
        }
        return nil
    }()

    static func run(_ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("vecfg-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Copy of s5 in a fresh directory.
    static func input() throws -> (dir: URL, file: URL) {
        let d = try tempDir()
        let f = d.appendingPathComponent("in.rvsc")
        try FileManager.default.copyItem(at: Fixtures.sample("s5.rvsc"), to: f)
        return (d, f)
    }
}

@Suite(.enabled(if: Fixtures.hasSamples, "needs private samples/"), .enabled(if: CLI.binary != nil, "vecfg not built next to the tests")) struct CLITests {
    @Test func refusesToOverwriteTheInput() throws {
        let (d, f) = try CLI.input()
        let before = try Data(contentsOf: f)
        try FileManager.default.createSymbolicLink(at: d.appendingPathComponent("link.rvsc"), withDestinationURL: f)
        try FileManager.default.linkItem(at: f, to: d.appendingPathComponent("hard.rvsc"))
        for out in [f.path, d.path + "/./in.rvsc", d.path + "/link.rvsc", d.path + "/hard.rvsc"] {
            let r = try CLI.run(["set", f.path, "2=53", "-o", out])
            #expect(r.status != 0, "\(out)")
            #expect(r.output.contains("refusing to overwrite"), "\(out)")
        }
        #expect(try Data(contentsOf: f) == before)
    }

    @Test func diffIsAgainstTheOriginal() throws {
        let (d, f) = try CLI.input()
        let old = try #require(try DeviceConfiguration(contentsOf: f).value(2))
        let new = old + 1
        let r = try CLI.run(["set", f.path, "2=\(new)", "-o", d.appendingPathComponent("out.rvsc").path])
        #expect(r.status == 0)
        #expect(r.output.contains(String(format: "%.2f → %.2f", old, new)), "\(r.output)")
    }

    @Test(arguments: [
        ["2=53", "-o", "OUT", "extra=1"],      // arguments after -o were ignored
        ["-1=5", "-o", "OUT"],                 // negative id trapped
        ["999=5", "-o", "OUT"],
        ["0=5", "-o", "OUT"],                  // whole flag words
        ["82=5", "-o", "OUT"],
        ["Flags#0=5", "-o", "OUT"],
        ["AssistEnabled=onn", "-o", "OUT"],    // `onn` used to turn the flag off
        ["2=nan", "-o", "OUT"],
        ["2=inf", "-o", "OUT"],
        ["=5", "-o", "OUT"],
        ["81=1", "-o", "OUT"],                 // grid code
    ])
    func rejectsBadAssignments(args: [String]) throws {
        let (d, f) = try CLI.input()
        let out = d.appendingPathComponent("out.rvsc")
        let r = try CLI.run(["set", f.path] + args.map { $0 == "OUT" ? out.path : $0 })
        #expect(r.status != 0, "\(args): \(r.output)")
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func flagValuesAreStrict() throws {
        let (d, f) = try CLI.input()
        let out = d.appendingPathComponent("out.rvsc")
        let r = try CLI.run(["set", f.path, "AssistEnabled=yes", "-o", out.path])
        #expect(r.status == 0)
        let c = try DeviceConfiguration(contentsOf: out)
        #expect(c.flag(SettingNames.flag(named: "_AssistEnabled")!))
    }

    /// A version-1 info section has no attribute bytes: the grid code must stay protected.
    @Test func gridCodeProtectedWithoutAttributes() throws {
        let d = try CLI.tempDir()
        let f = d.appendingPathComponent("v1.rvsc")
        let bytes = try Crafted.withInfo("s5.rvsc") { b in
            let n = Int(b[9]) | Int(b[10]) << 8
            b = [1, 0, 0, 0] + Array(b[4..<(11 + n)])
        }
        try Data(bytes).write(to: f)
        for key in ["81=1", "140=1"] {
            let r = try CLI.run(["set", f.path, key, "-o", d.appendingPathComponent("out.rvsc").path])
            #expect(r.status != 0)
            #expect(r.output.contains("protected"))
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: Fixtures.library.path)))
    func reconstructWithoutAssistants() throws {
        let r = try CLI.run(["reconstruct", Fixtures.library.path, Fixtures.sample("s1.rvsc").path])
        #expect(r.status == 0)
        #expect(r.output.contains("no assistants installed"))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: Fixtures.library.path)))
    func wizardAnswerParsing() throws {
        let base = ["wizard", Fixtures.library.path, Fixtures.sample("s5.rvsc").path, "ESS"]
        let ok = try CLI.run(base + ["k="])          // used to trap on the empty value
        #expect(ok.status == 0)
        #expect(ok.output.contains("finished"))
        let bad = try CLI.run(base + ["alSystem=x"])
        #expect(bad.status != 0)
        #expect(bad.output.contains("not a 32-bit integer"))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: Fixtures.library.path)))
    func installRefusesItsInputsAsOutput() throws {
        let (d, f) = try CLI.input()
        let r = try CLI.run(["install", Fixtures.library.path, f.path, Fixtures.sample("s5.rvsc").path, "-o", f.path])
        #expect(r.status != 0)
        #expect(r.output.contains("refusing to overwrite"))
        let ok = try CLI.run(["install", Fixtures.library.path, f.path, Fixtures.sample("s5.rvsc").path,
                              "-o", d.appendingPathComponent("out.rvsc").path])
        #expect(ok.status == 0, "\(ok.output)")
    }
}
