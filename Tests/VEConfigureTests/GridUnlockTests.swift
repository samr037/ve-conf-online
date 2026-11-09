import Foundation
import Testing
import VEKit
@testable import VEConfigure

private let samplesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("samples")
/// Victron's grid code password is never written in this repository: give it through VE_GRID_PASSWORD.
let gridKey = ProcessInfo.processInfo.environment["VE_GRID_PASSWORD"]?.trimmingCharacters(in: .whitespaces) ?? ""
let hasGridKey = gridKey.count == 12
private let gridSampleAvailable = hasGridKey
    && FileManager.default.fileExists(atPath: samplesDir.appendingPathComponent("s5.rvsc").path)
    && FileManager.default.fileExists(atPath: samplesDir.appendingPathComponent("s2.rvsc").path)

@MainActor @Suite struct GridUnlockTests {
    private var sample: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("samples/s5.rvsc")
    }
    /// The token VE Configure 9004248 wrote into s2 after the password was entered (s5 has none).
    private var referenceToken: [UInt8] {
        (try? DeviceConfiguration(contentsOf: samplesDir.appendingPathComponent("s2.rvsc")))?.data.tokens.first ?? []
    }
    private func password(_ c: DeviceConfiguration) throws -> String { gridKey }

    @Test(.enabled(if: hasGridKey, "set VE_GRID_PASSWORD")) func correctPasswordUnlocksOnlyItsSession() {
        var session = SessionState()
        let other = SessionState()
        let accepted = session.unlockGrid(with: "  \(gridKey.lowercased())  ")
        #expect(accepted)
        #expect(session.gridPasswordEntered)
        #expect(!other.gridPasswordEntered)
    }

    @Test func badPasswordsDoNotUnlock() {
        for input in ["", "x", "23456789ABCD", "23456789ABC", String(repeating: "A", count: 1000)] {
            var session = SessionState()
            let accepted = session.unlockGrid(with: input)
            #expect(!accepted)
            #expect(!session.gridPasswordEntered)
        }
    }

    @Test(.enabled(if: gridSampleAvailable, "Requires private s5 fixture")) func documentIsolationAndFileRoundTrip() throws {
        let first = try ConfigDocument(url: sample)
        let second = try ConfigDocument(url: sample)
        let key = try password(first.config)
        #expect(!first.session.gridPasswordEntered)
        #expect(!first.unlockGrid(with: "wrong"))
        let before = first.config.raw(142)
        first.setRaw(142, before ^ 1, actionName: "Test")
        #expect(first.config.raw(142) == before)
        #expect(first.unlockGrid(with: key))
        #expect(!second.session.gridPasswordEntered)
        let control = try #require(Catalog.shared.controls["GridCodeComboBox"])
        #expect(!Access.isLocked(control, first.ruleContext))
        #expect(Access.isLocked(control, second.ruleContext))
        first.setRaw(142, before ^ 1, actionName: "Test")
        #expect(first.config.raw(142) == before ^ 1)
        first.undoManager.undo()
        #expect(first.config.raw(142) == before)
        first.setRaw(142, before ^ 1, actionName: "Test")
        #expect(Access.forbiddenChanges(first.ruleContext).isEmpty)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("grid-unlock-\(UUID()).rvsc")
        defer { try? FileManager.default.removeItem(at: output) }
        try first.save(to: output)
        let reopened = try ConfigDocument(url: output)
        #expect(!reopened.session.gridPasswordEntered)
        #expect(reopened.config.raw(142) == before ^ 1)
        #expect(reopened.config.data.tokens == [referenceToken])
        #expect(abs(reopened.config.data.tokenTime - Int64(Date().timeIntervalSince1970)) < 5)
        #expect(Access.isLocked(control, reopened.ruleContext))
        #expect(first.session.gridPasswordEntered) // save does not end session
    }

    @Test(.enabled(if: gridSampleAvailable, "Requires private s5 fixture")) func gridSelectionKeepsConsistencyChecks() throws {
        let doc = try ConfigDocument(url: sample)
        #expect(doc.unlockGrid(with: try password(doc.config)))
        let code = try #require(doc.config.gridTable?.entries.keys.sorted().first { $0 > 1 && $0 != 21 && $0 != Int(doc.config.raw(81)) })
        doc.edit("Change Grid Code", control: "GridCodeComboBox") { GridPages.apply(gridCode: code, to: &$0) }
        #expect(Int(doc.config.raw(81)) == code)
        #expect(GridPages.paramsValid(doc.config))
        doc.setRaw(128, 65535, actionName: "Invalid checker")
        #expect(doc.integrityProblem != nil)
        #expect(!doc.canSave)
    }

    @Test(.enabled(if: gridSampleAvailable, "Requires private s5 fixture")) func verifiedAuthorizationDoesNotRenewOtherTokens() throws {
        var c = try DeviceConfiguration(contentsOf: sample)
        let auth = try #require(GridPassword(try password(c)))
        let expected = referenceToken
        c.data.tokens.append([1, 2, 3])
        auth.authorizeSave(&c, now: 123)
        #expect(c.data.tokens == [expected])
        #expect(c.data.tokenTime == 123)
    }
}
