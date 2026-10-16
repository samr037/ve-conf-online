import Foundation
import Testing
@testable import VEKit

// Regression tests for the 2026-10-16 audit (docs/audit/2026-10-16.md, priority 3): hostile .vap sources must
// give assembly errors, never crashes, hangs or runaway memory, and directives must follow the spec.

/// Assembles `source` as file `main` (and `files` for .SOURCE/.INSERT) through a root ` .SOURCE 'main'`.
private func asm(_ source: String, files: [String: String] = [:], lineBudget: Int = Assembler.maxLines) -> Assembler {
    let a = Assembler()
    a.lineBudget = lineBudget
    a.sourceProvider = { name in
        if name == "main" { return Latin1.encode(source) }
        return files[name].map(Latin1.encode)
    }
    let root = LineList(header: "root", lines: [SourceLine(Latin1.encode(" .SOURCE 'main'"))])
    _ = a.assemble(root: root)
    return a
}

private extension Assembler {
    var errors: [String] { messages.filter { $0.kind == .error || $0.kind == .fatal }.map(\.text) }
    var fatal: AssemblerMessage? { messages.first { $0.kind == .fatal } }
}

@Suite struct AssemblerLimitTests {
    @Test func sourceIncludingItselfIsFatal() {
        let a = asm(" .SOURCE 'main'")
        #expect(a.fatal?.text.hasPrefix("nesting too deep") == true, "\(a.messages)")
        #expect(a.messages.count == 1)
    }

    @Test func insertIncludingItselfIsFatal() {
        let a = asm(" .INSERT 'main'")
        #expect(a.fatal?.text.hasPrefix("nesting too deep") == true, "\(a.messages)")
    }

    @Test func assembleOfItselfIsFatal() {
        let a = asm("S .SET ' .ASSEMBLE S'\n .ASSEMBLE S")
        #expect(a.fatal?.text.hasPrefix("nesting too deep") == true, "\(a.messages)")
    }

    @Test func legitimateNestingStillWorks() {
        let a = asm(" .SOURCE 'a'\n .ASSEMBLE ' .ASSEMBLE '' DATA 3'''", files: ["a": " .INSERT 'b'", "b": " DATA 1\n DATA 2"])
        #expect(a.errors.isEmpty, "\(a.messages)")
        #expect(a.code == [1, 2, 3])
    }

    @Test func recursiveMacroHitsTheMacroLimit() {
        let a = asm("M .MACRO\n M\n .ENDM\n M")
        #expect(a.errors.contains("Macro nesting not allowed deeper than 255"), "\(a.messages.prefix(3))")
    }

    @Test func locationCounterIsCapped() {
        let a = asm("$ .SET 0x10000000\n DATA 1")
        #expect(a.fatal?.text.hasPrefix("location counter") == true, "\(a.messages)")
        #expect(a.code.isEmpty)
        let b = asm("$ .SET 4095\n DATA 1")
        #expect(b.errors.isEmpty)
        #expect(b.code.count == 4096 && b.code.last == 1)
    }

    @Test func nestedWhileLoopsHitTheGlobalBudget() {
        let a = asm("""
        I .SET 0
         .WHILE TRUE
        J .SET 0
         .WHILE TRUE
        K .SET 0
         .WHILE K<1000
        K .SET K+1
         .ENDW
         .ENDW
         .ENDW
        """, lineBudget: 200_000)
        #expect(a.fatal?.text.hasPrefix("Assembly stopped") == true, "\(a.messages.prefix(3))")
    }

    @Test func singleWhileLoopKeepsThe1024Cap() {
        let a = asm("""
        I .SET 0
         .WHILE TRUE
        I .SET I+1
         .ENDW
         DATA I AND 0xFF
         DATA I>>8
        """)
        #expect(a.errors == ["while loop must stop within 1024 iterations"])
        #expect(a.code == [0x01, 0x04])   // the body runs 1025 times
    }
}

@Suite struct AssemblerDirectiveTests {
    @Test func unsetRemovesAVariable() {
        let a = asm("X .SET 1\nX .UNSET\n DATA int(Known('X'))\nX .SET 2\n DATA X")
        #expect(a.errors.isEmpty, "\(a.messages)")
        #expect(a.code == [0, 2])
    }

    @Test func unsetOfAFixedLabelIsAnError() {
        let a = asm("F .EQU 3\nF .UNSET\n DATA F")
        #expect(a.errors == ["Labeltype (fixed/variable) different from previous pass"], "\(a.messages)")
        #expect(a.code == [3])
    }

    @Test func unsetOfAMacroParameterIsAnError() {
        let a = asm("M .MACRO G\nG .UNSET\n DATA G\n .ENDM\n M 7")
        #expect(a.errors == ["Cannot redefine a macro parameter"], "\(a.messages)")
        #expect(a.code == [7])
    }

    @Test func unsetFollowsTheSetTargetOrder() {
        // §5.4: a global *variable* is the target before the macro frame is consulted, exactly as for .SET.
        let a = asm("""
         .GLOBAL TRUE
        G .SET 6
         .GLOBAL FALSE
        M .MACRO G
        G .UNSET
         .ENDM
         M 1
         .IFDEF G
         DATA G
         .ELSE
         DATA 0xEE
         .ENDIF
        """)
        #expect(a.errors.isEmpty, "\(a.messages)")
        #expect(a.code == [0xEE])
    }

    @Test func unsetOfASystemLabelAndBadArity() {
        #expect(asm("$ .UNSET").errors == ["Cannot remove a system label"])
        #expect(asm("X .SET 1\nX .UNSET 1").errors == ["too many parameters"])
        #expect(asm(" .UNSET").errors == ["label expected"])
    }

    @Test func insertSharesTheConditionalStack() {
        // The inserted file closes the includer's block…
        let a = asm(" .IF TRUE\n .INSERT 'inc'\n DATA 2", files: ["inc": " DATA 1\n .ENDIF"])
        #expect(a.errors.isEmpty, "\(a.messages)")
        #expect(a.code == [1, 2])
        // …or leaves one open for the includer to close.
        let b = asm(" .INSERT 'inc'\n DATA 2\n .ELSE\n DATA 3\n .ENDIF", files: ["inc": " .IF TRUE\n DATA 1"])
        #expect(b.errors.isEmpty, "\(b.messages)")
        #expect(b.code == [1, 2])
        // A block left open at the end of the .SOURCE scope is still an error.
        let c = asm(" .INSERT 'inc'\n DATA 2", files: ["inc": " .IF TRUE\n DATA 1"])
        #expect(c.errors == ["expected .ENDIF"], "\(c.messages)")
        // Skip mode stops at the end of the inserted list.
        let d = asm(" .INSERT 'inc'\n DATA 2", files: ["inc": " .IF FALSE\n DATA 1"])
        #expect(d.errors.contains("expected .ENDIF"), "\(d.messages)")
    }

    @Test func endwOfAnotherListsWhileIsAnError() {
        let a = asm("I .SET 0\n .WHILE I<2\nI .SET I+1\n .INSERT 'inc'\n DATA I", files: ["inc": " .ENDW"])
        #expect(a.errors.contains("internal error with while construction"), "\(a.messages)")
    }
}
