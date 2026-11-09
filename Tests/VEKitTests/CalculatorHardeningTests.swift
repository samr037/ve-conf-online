import Foundation
import Testing
@testable import VEKit

// Regression tests for the 2026-10-16 audit (docs/audit/2026-10-16.md, priority 3): hostile expressions in a
// .vap must give calculation errors, never crashes, hangs or runaway memory.

private final class HEnv: CalculatorHost {
    var labels: [String: Label] = [:]
    func lookup(_ name: String) -> Label? { labels[name] }
    func readBack(bytes: Int, at address: Int32) -> Result<Int32, CalcError> { .success(-1) }
    func assistantText(_ key: Value) -> [UInt8]? { nil }
    func assistantLabelValue(_ name: String) -> Int32? { nil }
    func noteReadBackUsed() {}
}

/// Evaluates on the assembler's large-stack thread, as during an assembly.
private func ev(_ s: String, _ env: HEnv = HEnv()) -> Evaluation {
    var r = Evaluation()
    Assembler.withLargeStack { r = Calculator(host: env).evaluate(s) }
    return r
}

@Suite struct CalculatorHardeningTests {
    @Test func copyAndDelClipWithoutOverflow() {
        #expect(ev("copy('abc',0-2147483647-1,1)").value == .str(""))
        #expect(ev("copy('abc',0,0-2147483647-1)").value == .str(""))
        #expect(ev("copy('abc',2,2147483647)").value == .str("bc"))
        #expect(ev("copy('abc',-5,8)").value == .str("ab"))
        #expect(ev("del('abc',0-2147483647-1,1)").value == .str("abc"))
        #expect(ev("del('abc',2,2147483647)").value == .str("a"))
        #expect(ev("copy([]+1+2+3,1,2147483647)").value == .list([.int(2), .int(3)]))
        #expect(ev("del([]+1+2+3,2147483647,2147483647)").value == .list([.int(1), .int(2), .int(3)]))
    }

    @Test func userFunctionRecursionIsAnError() {
        let env = HEnv()
        env.labels["F("] = Label(value: .str("F(x)"), flags: 1, params: ["x"])
        let r = ev("F(1)", env)
        #expect(r.value == nil)
        #expect(r.error == CalcError.tooDeep.message)
        // Bounded recursion still works (each level is a function call plus a lazy OR operand).
        env.labels["G("] = Label(value: .str("n<1 OR 'G(n-1)'"), flags: 1, params: ["n"])
        #expect(ev("G(100)", env).value == .bool(true))
        #expect(ev("G(200)", env).error == CalcError.tooDeep.message)
    }

    @Test func valRecursionIsAnError() {
        let env = HEnv()
        env.labels["X"] = Label(value: .str("val(X)"), flags: 0)
        #expect(ev("val(X)", env).error == CalcError.tooDeep.message)
    }

    @Test func lazyLogicRecursionIsAnError() {
        let env = HEnv()
        env.labels["X"] = Label(value: .str("X OR TRUE"), flags: 0)
        #expect(ev("X OR TRUE", env).error == CalcError.tooDeep.message)
    }

    @Test func knownCannotSwallowTheLimit() {
        let env = HEnv()
        env.labels["K"] = Label(value: .str("known(K) OR known(K)"), flags: 0)
        // Exponential if known() hid the depth error from its caller; it must fail fast instead.
        let r = ev("known(K)", env)
        #expect(r.value == nil)
        #expect(r.error == CalcError.tooDeep.message)
        // After the failure the calculator is usable again.
        #expect(ev("known('1/0')", env).value == .bool(false))
    }

    @Test func exponentialFanOutIsBounded() {
        let env = HEnv()
        env.labels["F0("] = Label(value: .str("x"), flags: 1, params: ["x"])
        for k in 1...40 {
            env.labels["F\(k)("] = Label(value: .str("F\(k - 1)(x)+F\(k - 1)(x)"), flags: 1, params: ["x"])
        }
        #expect(ev("F10(1)", env).value == .int(1024))
        #expect(ev("F40(1)", env).error == CalcError.tooComplex.message)
    }

    @Test func hexDigitsAreCapped() {
        #expect(ev("hex(255,4)").value == .str("00FF"))
        #expect(ev("hex(255,10)").value == .str("00000000FF"))
        if case .string(let s)? = ev("hex(1,2147483647)").value { #expect(s.count == 32) } else { Issue.record("no value") }
    }

    @Test func stringsAndListsAreCapped() {
        let env = HEnv()
        env.labels["S"] = Label(value: .string([UInt8](repeating: 0x41, count: Calculator.maxLength)), flags: 0)
        #expect(ev("S+'x'", env).error == CalcError.tooLong.message)
        #expect(ev("ins(S,'x',1)", env).error == CalcError.tooLong.message)
        #expect(ev("str(S)", env).error == CalcError.tooLong.message)
        // A list sharing itself 40 times would print 2^40 elements.
        var l = Value.list([.int(1)])
        for _ in 0..<40 { l = .list([l, l]) }
        env.labels["L"] = Label(value: l, flags: 0)
        #expect(ev("str(L)", env).error == CalcError.tooLong.message)
        #expect(ev("len(L)", env).value == .int(2))
    }

    @Test func decimalLiteralsAbove32BitsAreRangeErrors() {
        #expect(ev("2147483647").value == .int(Int32.max))
        #expect(ev("0-2147483647-1").value == .int(Int32.min))
        #expect(ev("2147483648").error == CalcError.range.message)
        #expect(ev("99999999999999999999999999").error == CalcError.range.message)
        #expect(ev("0xFFFFFFFF").value == .int(-1))
        #expect(ev("known('4294967295')").value == .bool(false))
    }

    @Test func probesFromTheAuditStillEvaluate() {
        #expect(ev("'b'>'B'").value == .bool(true))
        #expect(ev("1=true").value == nil)
        #expect(ev("[]=[]").value == .bool(true))
        #expect(ev("sign(0)").value == .int(1))
        #expect(ev("abs(0-2147483647-1)").value == .int(Int32.min))
        #expect(ev("1<<32").value == .int(1))
        #expect(ev("5 MOD 0").value == nil)
        #expect(ev("known('1/0')").value == .bool(false))
    }
}
