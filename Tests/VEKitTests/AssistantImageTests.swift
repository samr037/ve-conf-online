import Foundation
import Testing
@testable import VEKit

@Suite struct AssistantImageFixTests {
    /// Audit #3/#14: an image that cannot hold code + ID directory + checksum, or of the wrong size, is refused.
    @Test func oversizeImageThrows() throws {
        let lib = try assistantLibrary()
        let c = try AssistantComposer(library: lib)
        c.items = [.init(package: try #require(lib.latest.first { $0.baseName == "ESS" }))]
        let room = 4096 - 4 - 2 * 3
        #expect(throws: (any Error).self) { try c.image(code: [UInt8](repeating: 0x11, count: room + 1)) }
        #expect(throws: (any Error).self) { try c.image(code: [UInt8](repeating: 0x11, count: 5000)) }
        #expect(throws: (any Error).self) { try c.image(code: [0x11], size: 2048) }
        let full = try c.image(code: [UInt8](repeating: 0x11, count: room))
        #expect(full.count == 4096)
        let ids = [c.framework.stop.id, c.items[0].package.id, c.framework.start.id]
        #expect(Array(full[room..<(room + 6)]) == ids.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
    }

    @Test func applyRefusesFailedBuildAndBadMemory() throws {
        let lib = try assistantLibrary()
        let s5 = try sampleConfig("s5")
        let c = try reconstructedComposer(for: s5, lib)
        var b = c.build()
        b.success = false
        #expect(throws: (any Error).self) { try c.apply(b, to: s5) }
        var small = s5
        small.data.assistantMemory = [UInt8](repeating: 0xFF, count: 100)
        #expect(throws: (any Error).self) { try c.apply(c.build(), to: small) }
    }

}

@Suite struct AssistantMetaFixTests {
    /// META's `BatteryType_VEC` carries the preset the caller matched.
    @Test func batteryTypeInMeta() throws {
        let s5 = try sampleConfig("s5")
        let lines = MetaGenerator.lines(for: s5, batteryType: 2)
        #expect(lines.contains("BatteryType_VEC .SET 2,4,true"))
    }

    /// The battery preset chosen by an assistant is applied first, then the assistant's own settings.
    @Test func batteryPresetHookRunsBeforeVECChanges() throws {
        let lib = try assistantLibrary()
        let s5 = try sampleConfig("s5")
        let c = try reconstructedComposer(for: s5, lib)
        let b = c.build()
        var order: [String] = []
        let (out, battery) = try c.apply(b, to: s5, extraChanges: ["BatteryType_VEC": .int(1), "eestBatteryCapacity_VEC": .int(321)]) { preset, cfg in
            order.append("preset \(preset)")
            cfg.setRaw(batteryCapacityID, 5)
        }
        #expect(order == ["preset 1"])
        #expect(battery == 1)
        #expect(out.raw(batteryCapacityID) == 321)
    }
}
