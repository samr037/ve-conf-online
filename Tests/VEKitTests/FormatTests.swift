import Foundation
import Testing
@testable import VEKit

enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func sample(_ name: String) -> URL { root.appendingPathComponent("samples/\(name)") }
    /// Victron's Assistant library (bundled in web/src/data/assistants); VE_ASSISTANT_LIBRARY overrides the path.
    static let library: URL = ProcessInfo.processInfo.environment["VE_ASSISTANT_LIBRARY"].map { URL(fileURLWithPath: $0) }
        ?? root.appendingPathComponent("web/src/data/assistants/all112.vfp")
    static var hasLibrary: Bool { FileManager.default.fileExists(atPath: library.path) }
    /// The sample device files are private and never published; tests that read them skip without them.
    static var hasSamples: Bool { FileManager.default.fileExists(atPath: sample("s5.rvsc").path) }
    /// Values the private samples are expected to hold (samples/expected.json, private like the samples).
    static let expectedURL = root.appendingPathComponent("samples/expected.json")
    static var hasExpected: Bool { FileManager.default.fileExists(atPath: expectedURL.path) }
    static func expected(_ sample: String) throws -> Expected {
        let all = try JSONSerialization.jsonObject(with: Data(contentsOf: expectedURL)) as? [String: Any]
        return Expected(values: try #require(all?[sample] as? [String: Any], "no \(sample) in samples/expected.json"))
    }
}

/// One sample's entry in samples/expected.json.
struct Expected {
    let values: [String: Any]
    func double(_ key: String) -> Double? { (values[key] as? NSNumber)?.doubleValue }
    func int(_ key: String) -> Int? { (values[key] as? NSNumber)?.intValue }
    func ints(_ key: String) -> [Int]? { (values[key] as? [NSNumber])?.map(\.intValue) }
    func bool(_ key: String) -> Bool? { (values[key] as? NSNumber)?.boolValue }
    func string(_ key: String) -> String? { values[key] as? String }
}

@Suite(.enabled(if: Fixtures.hasSamples, "needs private samples/")) struct SettingFileTests {
    @Test(arguments: ["s1.rvsc", "s2.rvsc", "s4.rvsc", "s5.rvsc"])
    func roundTrip(name: String) throws {
        let bytes = [UInt8](try Data(contentsOf: Fixtures.sample(name)))
        let file = try SettingFile(bytes: bytes)
        #expect(file.sections.map(\.name) == ["Mk2vscInfo", "BareSettingInfo", "BareSettingData"])
        #expect(file.encoded() == bytes)
    }

    @Test func detectsCorruption() throws {
        var bytes = [UInt8](try Data(contentsOf: Fixtures.sample("s5.rvsc")))
        bytes[200] ^= 0x01
        #expect(throws: FormatError.badChecksum(section: "BareSettingInfo")) { try SettingFile(bytes: bytes) }
    }
}

@Suite(.enabled(if: Fixtures.hasLibrary, "needs the assistant library")) struct AssistantLibraryTests {
    @Test func loadsAllPackages() throws {
        let lib = try AssistantLibrary(contentsOf: Fixtures.library)
        #expect(lib.packages.count == 161)
        let ess = try #require(lib.package(id: 0x18E))
        #expect(ess.baseName == "ESS")
        #expect(ess.source?.text.contains("MinimumVLLVersion") == true)
        #expect(Set(ess.scripts.keys) == ["en", "fr", "de", "es"])
    }
}
