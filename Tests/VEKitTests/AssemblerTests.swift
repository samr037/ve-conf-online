import Foundation
import Testing
@testable import VEKit

private final class Env: CalculatorHost {
    var labels: [String: Label] = [:]
    func lookup(_ name: String) -> Label? { labels[name] }
    func readBack(bytes: Int, at address: Int32) -> Result<Int32, CalcError> { .success(-1) }
    func assistantText(_ key: Value) -> [UInt8]? { nil }
    func assistantLabelValue(_ name: String) -> Int32? { nil }
    func noteReadBackUsed() {}
}

@Suite struct CalculatorTests {
    private let env = Env()
    private func eval(_ s: String) -> Value? { Calculator(host: env).evaluate(s).value }

    @Test func arithmeticAndPrecedence() {
        #expect(eval("1+2*3") == .int(7))
        #expect(eval("-2*3") == .int(-6))
        #expect(eval("0x10+0b11") == .int(19))
        #expect(eval("7/2") == .int(3))
        #expect(eval("-7/2") == .int(-3))
        #expect(eval("1<<4>>2") == .int(4))
        #expect(eval("(-1)>>28") == .int(15))
        #expect(eval("-1>>28") == .int(0))
        #expect(eval("1=1 AND 2=2") == .bool(true))
        #expect(eval("6 AND 3") == .int(2))
        #expect(eval("!0") == .int(-1))
        #expect(eval("!true") == .bool(false))
    }

    @Test func strings() {
        #expect(eval("'it''s'") == .str("it's"))
        #expect(eval("'a'#13'b'") == .string([0x61, 13, 0x62]))
        #expect(eval("'ab'+'cd'") == .str("abcd"))
        #expect(eval("str(5)") == .str("5"))
        #expect(eval("str('a')") == .str("'a'"))
        #expect(eval("copy('hello',2,3)") == .str("ell"))
        #expect(eval("pos('l','hello')") == .int(3))
        #expect(eval("len('abc')") == .int(3))
        #expect(eval("'abc'@2") == .str("b"))
        #expect(eval("val('3*4')") == .int(12))
    }

    @Test func lists() {
        #expect(eval("[]+1+'x'") == .list([.int(1), .str("x")]))
        #expect(eval("([]+1+2)@1") == .int(2))
        #expect(eval("len([]+1+2+3)") == .int(3))
        #expect(eval("str([]+1+'a')") == .str("([]+1+'a')"))
    }

    @Test func knownAndLazyLogic() {
        #expect(eval("Known('X')") == .bool(false))
        #expect(eval("!Known('X') OR 'X>5'") == .bool(true))
        env.labels["X"] = Label(value: .int(9), flags: 1)
        #expect(eval("Known('X')") == .bool(true))
        #expect(eval("!Known('X') OR 'X>5'") == .bool(true))
        #expect(eval("X+1") == .int(10))
    }

    @Test func userFunctions() {
        env.labels["ROUNDDIV("] = Label(value: .str("((a+(b>>1))/b)"), flags: 1, params: ["a", "b"])
        #expect(eval("ROUNDDIV(7,2)") == .int(4))
        #expect(eval("ROUNDDIV(ROUNDDIV(9,2),2)") == .int(3))
    }

    @Test func errors() {
        #expect(eval("1+") == nil)
        #expect(eval("1/0") == nil)
        #expect(eval("1+'a'") == nil)
        #expect(eval("err(true,'boom')") == nil)
        #expect(eval("err(false,'boom')") == .int(0))
    }
}

@Suite struct AssemblerCoreTests {
    private func assemble(_ source: String) -> (Assembler, Bool) {
        let a = Assembler()
        a.sourceProvider = { name in name == "main" ? Latin1.encode(source) : nil }
        let root = LineList(header: "root", lines: [SourceLine(Latin1.encode(" .SOURCE 'main'"))])
        let ok = a.assemble(root: root)
        return (a, ok)
    }

    @Test func dataLabelsAndForwardReferences() {
        let (a, ok) = assemble("""
         DATA 1
        Start:
         DATA Target
         DATA Start
        Target:
         DATA 0xFF
        """)
        #expect(ok, "\(a.messages)")
        #expect(a.code == [1, 3, 1, 0xFF])
    }

    @Test func macrosConditionalsAndWhile() {
        let (a, ok) = assemble("""
        EMIT .MACRO 1,v,s:name
         .IF Params=2
         DATA len(name)
         .ELSE
         DATA v
         .ENDIF
         .ENDM
        Count .SET 0
         .WHILE Count<3
         EMIT Count
        Count .SET Count+1
         .ENDW
         EMIT 9,abcd
         .ASSEMBLE ' DATA '+str(40+2)
        """)
        #expect(ok, "\(a.messages)")
        #expect(a.code == [0, 1, 2, 4, 42])
    }

    @Test func macroLocalLabels() {
        let (a, ok) = assemble("""
        LOOP .MACRO
         .LOCAL Here
        Here:
         DATA Here
         .ENDM
         LOOP
         LOOP
        """)
        #expect(ok, "\(a.messages)")
        #expect(a.code == [0, 1])
    }

    @Test func fixedLabelRedefinitionIsAnError() {
        let (a, ok) = assemble("""
        X .EQU 1
        X .EQU 2
        """)
        #expect(!ok)
        #expect(a.messages.contains { $0.text.hasPrefix("label value different") })
    }
}

@Suite struct AssistantEndToEndTests {
    /// The user's ESS setup: recover the answers from the device program, re-assemble from those answers
    /// alone, and get the exact 4096-byte image the inverter holds (code, ID directory, checksum).
    @Test(arguments: ["s2.rvsc", "s5.rvsc"])
    func reconstructAndRebuildByteIdentical(name: String) throws {
        let config = try DeviceConfiguration(contentsOf: Fixtures.sample(name))
        let library = try AssistantLibrary(contentsOf: Fixtures.library)
        let composer = try AssistantComposer(library: library)
        composer.meta = MetaGenerator.source(for: config)
        let r = try composer.reconstruct(image: config.data.assistantMemory)
        #expect(r.success, "\(r.messages)")
        #expect(composer.items.map(\.package.id) == [0x18C])
        #expect(composer.answers["ESS"]?.answers["alSystem"]?.value == 4)
        let b = composer.build()
        #expect(b.success, "\(b.messages)")
        #expect(composer.image(code: b.code) == config.data.assistantMemory)
    }

    @Test func imageChecksumMatchesDevice() throws {
        for name in ["s1.rvsc", "s2.rvsc", "s4.rvsc", "s5.rvsc"] {
            let mem = try DeviceConfiguration(contentsOf: Fixtures.sample(name)).data.assistantMemory
            let stored = UInt32(mem[4092]) | UInt32(mem[4093]) << 8 | UInt32(mem[4094]) << 16 | UInt32(mem[4095]) << 24
            #expect(AssistantComposer.checksum(mem[0..<4092]) == stored)
        }
    }
}
