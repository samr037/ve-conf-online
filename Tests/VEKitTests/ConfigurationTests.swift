import Foundation
import Testing
@testable import VEKit

@Suite struct ConfigurationTests {
    @Test(arguments: ["s1.rvsc", "s2.rvsc", "s4.rvsc", "s5.rvsc"])
    func roundTrip(name: String) throws {
        let bytes = [UInt8](try Data(contentsOf: Fixtures.sample(name)))
        let config = try DeviceConfiguration(file: try SettingFile(bytes: bytes))
        #expect(config.encoded() == bytes)
    }

    @Test func userValues() throws {
        let c = try DeviceConfiguration(contentsOf: Fixtures.sample("s5.rvsc"))
        #expect(c.firmware.number == 2_623_552)
        #expect(c.firmware.version == 552)
        #expect(c.serial == "HQ0000XXXXX")
        #expect(c.value(2) == 52.0)   // absorption
        #expect(c.value(3) == 51.0)   // float
        #expect(c.value(6) == 32.0)   // AC-in limit
        #expect(c.raw(81) == 9)       // France
        #expect(c.flag(SettingNames.flag(named: "_LithiumBattery")!))
        #expect(!c.flag(SettingNames.flag(named: "_AssistEnabled")!))
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
