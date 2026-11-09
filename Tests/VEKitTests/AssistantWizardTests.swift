import Foundation
import Testing
@testable import VEKit

// Regression tests for the 2026-10-16 audit (docs/audit/2026-10-16.md), ported from the auditor's probes.

func sampleConfig(_ name: String) throws -> DeviceConfiguration {
    try DeviceConfiguration(contentsOf: Fixtures.sample("\(name).rvsc"))
}
func assistantLibrary() throws -> AssistantLibrary { try AssistantLibrary(contentsOf: Fixtures.library) }
let batteryCapacityID = SettingNames.settings.firstIndex(of: "eestBatteryCapacity")!

/// A composer holding a configuration's assistants (reconstructed from its program).
func reconstructedComposer(for c: DeviceConfiguration, _ lib: AssistantLibrary) throws -> AssistantComposer {
    let composer = try AssistantComposer(library: lib)
    composer.meta = MetaGenerator.source(for: c)
    let r = try composer.reconstruct(image: c.data.assistantMemory)
    #expect(r.success, "\(r.messages)")
    return composer
}

/// Walks a wizard answering Next with the shown values, or `answers[label]` where given.
@discardableResult
func walkWizard(_ w: AssistantWizard, answers: [String: Int32] = [:], limit: Int = 300) -> (AssistantBuildResult?, [String]) {
    var trail: [String] = []
    while trail.count < limit {
        switch w.status {
        case .step(let p):
            trail.append(p.step.id)
            var v = p.values
            for (i, l) in p.labels.enumerated() { if let o = answers[l] { v[i] = o } }
            w.next(v)
        case .finished(let r): return (r, trail)
        case .failed, .cancelled: return (nil, trail)
        }
    }
    return (nil, trail)
}

@Suite(.enabled(if: Fixtures.hasSamples, "needs private samples/"), .serialized) struct AssistantWizardFixTests {
    /// Audit #4: the answers given in the wizard reach the assistant settings (one continuous assembly).
    @Test func essCapacityReachesTheConfiguration() throws {
        let lib = try assistantLibrary()
        let s5 = try sampleConfig("s5")
        let c = try reconstructedComposer(for: s5, lib)
        #expect(c.answers["ESS"]?.answers["alBatteryCapacity"]?.value != 200)
        let (r, _) = walkWizard(c.wizard(for: "ESS"), answers: ["alBatteryCapacity": 200])
        let result = try #require(r)
        #expect(c.answers["ESS"]?.answers["alBatteryCapacity"]?.value == 200)
        #expect(result.vecChanges["eestBatteryCapacity_VEC"] == .int(200))
        let b = c.build()
        #expect(b.success)
        let (out, _) = try c.apply(b, to: s5, extraChanges: result.vecChanges)
        #expect(out.raw(batteryCapacityID) == 200)
    }

    /// Audit #4: a new ESS on s1 (no assistants), answered like the user did, sets the battery capacity the way the
    /// real VE Configure did when it produced s2.
    @Test func newESSOnS1LikeS2() throws {
        let lib = try assistantLibrary()
        let s1 = try sampleConfig("s1"), s2 = try sampleConfig("s2")
        let donor = try reconstructedComposer(for: s2, lib)
        let answers = try #require(donor.answers["ESS"]).answers.mapValues(\.value)
        let c = try AssistantComposer(library: lib)
        c.meta = MetaGenerator.source(for: s1)
        c.items = [.init(package: try #require(lib.latest.first { $0.baseName == "ESS" }))]
        let (r, _) = walkWizard(c.wizard(for: "ESS"), answers: answers)
        let result = try #require(r)
        #expect(c.answers["ESS"]?.answers["alBatteryCapacity"]?.value == answers["alBatteryCapacity"])
        let b = c.build()
        #expect(b.success)
        let (out, _) = try c.apply(b, to: s1, extraChanges: result.vecChanges)
        #expect(out.raw(batteryCapacityID) == s2.raw(batteryCapacityID))
        #expect(out.raw(batteryCapacityID) == 96)
    }

    /// Audit #5: reconfiguring ESS from a lead-acid system to lithium resets the DC cut-off curve to the lithium
    /// defaults (`alSetCurveDefault .ALS 1`, a label no `.AUE` binds).
    @Test func leadToLithiumGetsLithiumCutOffCurve() throws {
        let lib = try assistantLibrary()
        let s1 = try sampleConfig("s1")
        let c = try AssistantComposer(library: lib)
        c.meta = MetaGenerator.source(for: s1)
        c.items = [.init(package: try #require(lib.latest.first { $0.baseName == "ESS" }))]
        let (first, _) = walkWizard(c.wizard(for: "ESS"), answers: ["alSystem": 0])
        #expect(first != nil)
        let lead = ["alDC0", "alDC1", "alDC2", "alDC3"].map { c.answers["ESS"]?.answers[$0]?.value }
        #expect(lead == [4800, 4500, 4220, 4000])
        var shownCurve: [Int32] = []
        let w = c.wizard(for: "ESS")
        var n = 0
        while n < 60, case .step(let p) = w.status {
            n += 1
            var v = p.values
            if p.step.id == "aidSystem" { v = [4] }
            if p.labels.contains("alDC0") { shownCurve = p.values }
            w.next(v)
        }
        guard case .finished = w.status else { Issue.record("wizard did not finish: \(w.status)"); return }
        let li = ["alDC0", "alDC1", "alDC2", "alDC3"].map { c.answers["ESS"]?.answers[$0]?.value }
        #expect(li == [5200, 5000, 4920, 4800])
        #expect(shownCurve.isEmpty || shownCurve == [5200, 5000, 4920, 4800])
    }

    /// Straight Next through an installed assistant changes nothing: same answers, byte-identical program.
    @Test func replayWithoutChangesIsIdentical() throws {
        let lib = try assistantLibrary()
        let s5 = try sampleConfig("s5")
        let c = try reconstructedComposer(for: s5, lib)
        let before = c.answers
        let (r, trail) = walkWizard(c.wizard(for: "ESS"))
        let result = try #require(r)
        #expect(trail.count > 3)
        #expect(c.answers["ESS"]?.answers.mapValues(\.value) == before["ESS"]?.answers.mapValues(\.value))
        let b = c.build()
        #expect(try c.image(code: b.code) == s5.data.assistantMemory)
        #expect(try c.image(code: result.code) == s5.data.assistantMemory)
    }

    /// Previous goes back one shown step and the wizard still completes to the same program.
    @Test func previousThenNextCompletes() throws {
        let lib = try assistantLibrary()
        let s5 = try sampleConfig("s5")
        let c = try reconstructedComposer(for: s5, lib)
        let w = c.wizard(for: "ESS")
        var seen: [String] = []
        var backs = 0
        while seen.count < 100, case .step(let p) = w.status {
            seen.append(p.step.id)
            if seen.count == 3 && backs == 0 {
                backs = 1
                w.previous()
                guard case .step(let q) = w.status else { Issue.record("no step after previous"); return }
                #expect(q.step.id == seen[1])
                continue
            }
            w.next(p.values)
        }
        guard case .finished(let r) = w.status else { Issue.record("not finished: \(w.status)"); return }
        #expect(try c.image(code: r.code) == s5.data.assistantMemory)
    }

    /// Audit #19: after Cancel the wizard is inert; the composer's answers are untouched.
    @Test func cancelledWizardIgnoresNext() throws {
        let lib = try assistantLibrary()
        let s5 = try sampleConfig("s5")
        let c = try reconstructedComposer(for: s5, lib)
        let before = c.answers
        let w = c.wizard(for: "ESS")
        var last: [Int32] = []
        for _ in 0..<3 { if case .step(let p) = w.status { last = p.values; w.next(p.values) } }
        w.cancel()
        guard case .cancelled = w.status else { Issue.record("status \(w.status)"); return }
        w.next(last)
        w.previous()
        guard case .cancelled = w.status else { Issue.record("status after next \(w.status)"); return }
        #expect(c.answers == before)
    }

    /// A finished wizard stays finished.
    @Test func finishedWizardIgnoresNext() throws {
        let lib = try assistantLibrary()
        let c = try reconstructedComposer(for: try sampleConfig("s5"), lib)
        let w = c.wizard(for: "ESS")
        _ = walkWizard(w)
        guard case .finished = w.status else { Issue.record("status \(w.status)"); return }
        w.next([1]); w.previous(); w.cancel()
        guard case .finished = w.status else { Issue.record("status after next \(w.status)"); return }
    }

    /// A wizard dropped while it waits for an answer releases its worker.
    @Test func abandonedWizardDoesNotHang() throws {
        let lib = try assistantLibrary()
        let c = try reconstructedComposer(for: try sampleConfig("s5"), lib)
        for _ in 0..<3 {
            var w: AssistantWizard? = c.wizard(for: "ESS")
            if case .step(let p)? = w?.status { w?.next(p.values) }
            w = nil
        }
        let (r, _) = walkWizard(c.wizard(for: "ESS"))
        #expect(r != nil)
    }
}
