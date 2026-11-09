import Foundation
import Testing
@testable import VEKit

@Suite(.enabled(if: Fixtures.hasSamples, "needs private samples/")) struct ConfigurationTests {
    @Test(arguments: ["s1.rvsc", "s2.rvsc", "s4.rvsc", "s5.rvsc"])
    func roundTrip(name: String) throws {
        let bytes = [UInt8](try Data(contentsOf: Fixtures.sample(name)))
        let config = try DeviceConfiguration(file: try SettingFile(bytes: bytes))
        #expect(config.encoded() == bytes)
    }

    /// The sample's values, against samples/expected.json.
    @Test(.enabled(if: Fixtures.hasExpected, "needs samples/expected.json")) func sampleValues() throws {
        let c = try DeviceConfiguration(contentsOf: Fixtures.sample("s5.rvsc"))
        let e = try Fixtures.expected("s5")
        let firmware = try #require(e.int("firmware")), version = try #require(e.int("firmwareVersion"))
        let prefix = try #require(e.string("serialPrefix")), gridCode = try #require(e.int("gridCode"))
        #expect(Int(c.firmware.number) == firmware)
        #expect(Int(c.firmware.version) == version)
        #expect(c.serial?.count == 11 && c.serial?.hasPrefix(prefix) == true)
        #expect(c.value(2) == e.double("absorption"))
        #expect(c.value(3) == e.double("float"))
        #expect(c.value(6) == e.double("acInputLimit"))
        #expect(Int(c.raw(81)) == gridCode)
        #expect(c.flag(SettingNames.flag(named: "_LithiumBattery")!) == e.bool("lithium"))
        #expect(c.flag(SettingNames.flag(named: "_AssistEnabled")!) == e.bool("assistEnabled"))
        #expect(c.data.assistantMemory.count == 4096)
    }

    @Test func editsChangeOnlyWhatTheyShould() throws {
        let original = try DeviceConfiguration(contentsOf: Fixtures.sample("s5.rvsc"))
        var c = original
        c.setValue(2, 56.4)
        c.setFlag(SettingNames.flag(named: "_AssistEnabled")!, true)
        #expect(c.value(2) == 56.4)
        #expect(c.flag(5))
        let reread = try DeviceConfiguration(file: try SettingFile(bytes: c.encoded()))
        #expect(reread.value(2) == 56.4)
        #expect(reread.data.assistantMemory == original.data.assistantMemory)
        let changed = (0..<192).filter { reread.raw($0) != original.raw($0) }
        #expect(changed == [0, 2])
    }

    @Test func clampsToDeviceRange() throws {
        var c = try DeviceConfiguration(contentsOf: Fixtures.sample("s5.rvsc"))
        c.setValue(2, 99)
        #expect(c.value(2) == 64.0)
    }

    @Test func canonicalRLERoundTrips() throws {
        let c = try DeviceConfiguration(contentsOf: Fixtures.sample("s5.rvsc"))
        let mem = c.data.assistantMemory
        let enc = RLE.encode(mem, tokens: nil)
        #expect(try RLE.decode(enc).memory == mem)
    }
}
