import Foundation
import Testing
@testable import VEKit

// Regression tests for the 2026-10-16 audit (docs/audit/2026-10-16.md, wizard field items 27-29 and priority 3):
// Delphi Format in wizard texts, the Generic step, and entry-field display/parse.

@Suite struct WizardFormatTests {
    private let args: [Value] = [.int(255), .str("ab"), .int(-3)]
    private func f(_ s: String) -> String { WizardStepContent.format(s, args) }

    @Test func indexesAndSequentialArguments() {
        #expect(f("%0:s %1:s") == "255 ab")
        #expect(f("%s|%s|%s|%s") == "255|ab|-3|")   // missing argument: empty
        #expect(f("%1:s %s") == "ab -3")           // sequential continues after an explicit index
        #expect(f("%2:d %s") == "-3 ")
        #expect(f("100% sure") == "100% sure")
        #expect(f("50%%") == "50%")
    }

    @Test func widthPrecisionAndTypes() {
        #expect(f("[%5d]") == "[  255]")
        #expect(f("[%-5s]") == "[255  ]")
        #expect(f("[%1:-4s]") == "[ab  ]")
        #expect(f("[%0:5s]") == "[  255]")
        #expect(f("%0:x") == "FF")
        #expect(f("%0:.4x") == "00FF")
        #expect(f("%2:.3d") == "-003")
        #expect(f("%2:u") == "4294967293")
        #expect(f("%1:.1s") == "a")
        #expect(f("[%*d]") == "[" + String(repeating: " ", count: 253) + "ab]")   // * takes the width from an argument
        #expect(WizardStepContent.format("%0:.2f", [.int(3)]).hasPrefix("3"))
        #expect(WizardStepContent.format("%0:.0n", [.int(3)]) == "3")
        #expect(f("%1:k") == "ab")   // the sources' unknown %n:k shows like %s
    }

    @Test func hostileSpecifiersDoNotCrash() {
        #expect(WizardStepContent.format("%9223372036854775807:s", [.int(1)]) == "%9223372036854775807:s")
        #expect(WizardStepContent.format("%99999999999999999999999d", [.int(1)]).hasPrefix("%"))
        #expect(WizardStepContent.format("%2147483647:s", [.int(1)]) == "")
        #expect(WizardStepContent.format("%2147483647d", [.int(1)]).count == 4096)   // width capped
        #expect(WizardStepContent.format("%0:.2147483647d", [.int(1)]).count == 64)   // precision capped
        #expect(f("%q %") == "%q %")
    }

    @Test func genericInsertsItsTextUnformatted() {
        let step = AssistantStepDefinition(id: "x", stepName: "Generic", kind: .entry, inSummary: false, fields: [], buttons: 0)
        let c = WizardStepContent(step: step, text: nil, format: [.str("%1:s"), .str("LEAK"), .str("Title %0:s")])
        // The section text is the last argument as is; each line is then formatted once.
        #expect(c.title == "Title %1:s")
    }
}

@Suite struct WizardFieldTests {
    private let dec = AssistantStepDefinition.Field(precision: .decimals(1), unitCode: "N", min: 0, max: 100000, defaultValue: 0)
    private let time = AssistantStepDefinition.Field(precision: .time, unitCode: "N", min: -1439, max: 1439, defaultValue: 0)

    @Test func nonFiniteAndNonNumbersAreRejected() {
        let f = AssistantStepDefinition.Field(precision: .decimals(2), unitCode: "N", min: 0, max: 100, defaultValue: 0)
        for t in ["nan", "NaN", "inf", "-infinity", "0x10", "1e3", "", "-", ".", "1,2,3.4.5", "12abc"] {
            #expect(f.parse(t) == nil, "\(t)")
        }
        let l = AssistantStepDefinition.Field(precision: .list, unitCode: "N", min: 0, max: 5, defaultValue: 0)
        #expect(l.parse("nan") == nil)
        #expect(l.parse("3") == 3)
    }

    @Test func displayHasNoGroupingAndReadsBack() {
        let shown = dec.display(12345)
        #expect(!shown.contains { !$0.isNumber && $0 != "." && $0 != "," }, "\(shown)")
        #expect(dec.parse(shown) == 12345)
    }

    @Test func parseToleratesGroupingAndBothDecimalMarks() {
        #expect(dec.parse("1 234,5") == 12345)
        #expect(dec.parse("1\u{00A0}234,5") == 12345)
        #expect(dec.parse("1\u{202F}234.5") == 12345)
        #expect(dec.parse("1,234.5") == 12345)
        #expect(dec.parse("1.234,5") == 12345)
        #expect(dec.parse("1'234.5") == 12345)
        #expect(dec.parse(" 46,5 ") == 465)
        #expect(dec.parse("99999999999999999999") == 100000)   // clamped
    }

    @Test func timesAreSignedAndOverflowSafe() {
        #expect(time.display(-1) == "-00:01")
        #expect(time.display(-90) == "-01:30")
        #expect(time.display(75) == "01:15")
        #expect(time.parse("-1:30") == -90)
        #expect(time.parse("-0:30") == -30)
        #expect(time.parse("1:30") == 90)
        #expect(time.parse(time.display(-1)) == -1)
        #expect(time.parse("300000000000000000:00") == 1439)
        #expect(time.parse("99999999999999999999999:00") == 1439)
        #expect(time.parse("1:-30") == nil)
        #expect(time.parse("nan:00") == nil)
        #expect(time.parse("1:2:3") == nil)
    }
}
