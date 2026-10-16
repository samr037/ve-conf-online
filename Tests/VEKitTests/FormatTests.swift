import Foundation
import Testing
@testable import VEKit

enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func sample(_ name: String) -> URL { root.appendingPathComponent("samples/\(name)") }
    static let library = root.appendingPathComponent("vendor/extracted/VE Configure tools/Assistants/all112.vfp")
    /// Victron's assistant library lives in the gitignored vendor/ tree; tests that need it skip on a clean clone.
    static var hasLibrary: Bool { FileManager.default.fileExists(atPath: library.path) }
}

@Suite struct SettingFileTests {
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

@Suite(.enabled(if: Fixtures.hasLibrary, "needs vendor/ assistant library")) struct AssistantLibraryTests {
    @Test func loadsAllPackages() throws {
        let lib = try AssistantLibrary(contentsOf: Fixtures.library)
        #expect(lib.packages.count == 161)
        let ess = try #require(lib.package(id: 0x18E))
        #expect(ess.baseName == "ESS")
        #expect(ess.source?.text.contains("MinimumVLLVersion") == true)
        #expect(Set(ess.scripts.keys) == ["en", "fr", "de", "es"])
    }
}
