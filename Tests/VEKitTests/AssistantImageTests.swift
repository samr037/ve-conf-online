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
        #expect(AssistantComposer.installedIDs(in: full, library: lib) == ids.reversed())
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

    /// Audit #34: a nearly full program still compares equal (the ID directory and checksum are not code).
    @Test(arguments: [0, 4, 10, 15, 16, 20])
    func nearlyFullMemoryTrimsTheDirectory(slack: Int) throws {
        let lib = try assistantLibrary()
        let c = try AssistantComposer(library: lib)
        c.items = [.init(package: try #require(lib.latest.first { $0.baseName == "ESS" }))]
        let trailer = 4 + 2 * 3
        let code = [UInt8](repeating: 0x11, count: 4096 - trailer - slack)
        let img = try c.image(code: code)
        #expect(AssistantComposer.trimmed(img, codeLength: code.count, trailer: trailer) == code)
        #expect(AssistantComposer.trimmed(code, codeLength: code.count) == code)
    }

    /// Audit #13: the ID list ends at asfStop by name; empty or stub memory reconstructs to "no assistants".
    @Test func emptyAndStubMemoryReconstructEmpty() throws {
        let lib = try assistantLibrary()
        for mem in [[UInt8](repeating: 0xFF, count: 4096), AssistantComposer.emptyImage()] {
            let c = try AssistantComposer(library: lib)
            let r = try c.reconstruct(image: mem)
            #expect(r.success)
            #expect(c.items.isEmpty)
            #expect(r.code.isEmpty)
        }
        let s1 = try sampleConfig("s1")
        let c = try AssistantComposer(library: lib)
        c.meta = MetaGenerator.source(for: s1)
        let r = try c.reconstruct(image: s1.data.assistantMemory)
        #expect(r.success, "\(r.messages)")
        #expect(c.items.isEmpty)
    }

    @Test func idListStopsAtTheStopPackage() throws {
        let lib = try assistantLibrary()
        let s5 = try sampleConfig("s5")
        let ids = AssistantComposer.installedIDs(in: s5.data.assistantMemory, library: lib)
        #expect(ids == [0x15, 0x18C, 0x0E])
    }
}

@Suite struct AssistantMetaFixTests {
    /// META's `BatteryType_VEC` carries the preset the caller matched.
    @Test func batteryTypeInMeta() throws {
        let s5 = try sampleConfig("s5")
        let lines = MetaGenerator.lines(for: s5, batteryType: 2)
        #expect(lines.contains("BatteryType_VEC .SET 2,4,true"))
    }

    /// FUN_0050eb9c-style META edits (used by the 0xA36 `cDeviceInfo xor 3` readback retry).
    @Test func metaEquEdit() throws {
        let meta = MetaGenerator.source(for: try sampleConfig("s5"))
        let info = try #require(MetaGenerator.equValue("cDeviceInfo", in: meta))
        let edited = MetaGenerator.replacingEqu("cDeviceInfo", with: "99", in: meta)
        #expect(MetaGenerator.equValue("cDeviceInfo", in: edited) == "99")
        #expect(MetaGenerator.replacingEqu("cDeviceInfo", with: info, in: edited) == meta)
        #expect(MetaGenerator.replacingEqu("NoSuchLabel", with: "1", in: meta) == meta)
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
