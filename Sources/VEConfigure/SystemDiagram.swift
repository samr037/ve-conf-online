import SwiftUI

/// Parts of the installation a setting can act on. A page lights the parts it governs.
enum DiagramPart: String, CaseIterable, Hashable, Codable {
    case acIn, acIn2, transferSwitch, inverter, charger, acOut, dcBus, battery, relay, feedIn, generator
}

/// The user's installation drawn as a single-line diagram, in the style of Victron's manuals.
/// AC source(s) on the left, the Multi in the centre, loads on the right, the battery below.
struct SystemDiagram: View {
    var lit: Set<DiagramPart>
    var model: String
    var hasSecondInput: Bool
    var showsRelay: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || flows.isEmpty)) { context in
            Canvas { ctx, size in
                draw(in: &ctx, size: size, phase: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(height: 132)
        .background(Theme.drafting)
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    /// Direction of energy for animated paths: charging flows AC → battery, inverting battery → loads.
    private var flows: [Flow] {
        var f: [Flow] = []
        if lit.contains(.charger) { f.append(.charge) }
        if lit.contains(.inverter) { f.append(.invert) }
        if lit.contains(.feedIn) { f.append(.feedIn) }
        return f
    }

    private enum Flow { case charge, invert, feedIn }

    private var accessibilitySummary: String {
        let names = lit.map(\.rawValue).sorted().joined(separator: ", ")
        return "System diagram of the \(model). Highlighted: \(names.isEmpty ? "none" : names)."
    }

    // MARK: Drawing

    private func draw(in ctx: inout GraphicsContext, size: CGSize, phase: Double) {
        drawGrid(&ctx, size)
        let midY = size.height * 0.36
        let left = max(28, size.width * 0.06)
        let right = size.width - left
        let multi = CGRect(x: size.width * 0.5 - 70, y: midY - 26, width: 140, height: 52)
        let acIn1 = CGPoint(x: left + 14, y: hasSecondInput ? midY - 14 : midY)
        let acIn2 = CGPoint(x: left + 14, y: midY + 18)
        let load = CGPoint(x: right - 14, y: midY)
        let battery = CGRect(x: multi.midX - 22, y: size.height - 30, width: 44, height: 16)

        // AC-in 1: source circle, conductor to the Multi.
        let in1Lit = lit.contains(.acIn) || lit.contains(.charger) || lit.contains(.feedIn) || lit.contains(.transferSwitch)
        acSource(&ctx, at: acIn1, lit: lit.contains(.acIn), label: hasSecondInput ? "AC-in 1" : "AC in",
                 generator: false)
        conductor(&ctx, from: CGPoint(x: acIn1.x + 12, y: acIn1.y), to: CGPoint(x: multi.minX, y: acIn1.y),
                  color: Theme.acLine, lit: in1Lit,
                  flow: lit.contains(.feedIn) ? -1 : lit.contains(.charger) ? 1 : 0, phase: phase)
        if hasSecondInput {
            let in2Lit = lit.contains(.acIn2) || lit.contains(.generator)
            acSource(&ctx, at: acIn2, lit: in2Lit, label: "AC-in 2", generator: true)
            conductor(&ctx, from: CGPoint(x: acIn2.x + 12, y: acIn2.y), to: CGPoint(x: multi.minX, y: acIn2.y),
                      color: Theme.acLine, lit: in2Lit, flow: 0, phase: phase)
        }

        // AC-out to the loads.
        let outLit = lit.contains(.acOut) || lit.contains(.inverter)
        conductor(&ctx, from: CGPoint(x: multi.maxX, y: midY), to: CGPoint(x: load.x - 12, y: midY),
                  color: Theme.acLine, lit: outLit, flow: lit.contains(.inverter) ? 1 : 0, phase: phase)
        loadSymbol(&ctx, at: load, lit: outLit)

        // DC: positive and negative to the battery.
        let dcLit = lit.contains(.dcBus) || lit.contains(.battery) || lit.contains(.charger) || lit.contains(.inverter)
        let dcFlow: Double = lit.contains(.charger) ? 1 : (lit.contains(.inverter) || lit.contains(.feedIn)) ? -1 : 0
        conductor(&ctx, from: CGPoint(x: multi.midX - 10, y: multi.maxY), to: CGPoint(x: multi.midX - 10, y: battery.minY),
                  color: Theme.dcPositive, lit: dcLit, flow: dcFlow, phase: phase)
        conductor(&ctx, from: CGPoint(x: multi.midX + 10, y: battery.minY), to: CGPoint(x: multi.midX + 10, y: multi.maxY),
                  color: Theme.dcNegative, lit: dcLit, flow: dcFlow, phase: phase)
        batterySymbol(&ctx, in: battery, lit: lit.contains(.battery) || lit.contains(.charger))

        multiBlock(&ctx, in: multi)
        if showsRelay { relaySymbol(&ctx, at: CGPoint(x: multi.maxX - 18, y: multi.minY - 14), lit: lit.contains(.relay)) }
    }

    private func drawGrid(_ ctx: inout GraphicsContext, _ size: CGSize) {
        var p = Path()
        stride(from: 0, through: size.width, by: 16).forEach { p.move(to: CGPoint(x: $0, y: 0)); p.addLine(to: CGPoint(x: $0, y: size.height)) }
        stride(from: 0, through: size.height, by: 16).forEach { p.move(to: CGPoint(x: 0, y: $0)); p.addLine(to: CGPoint(x: size.width, y: $0)) }
        ctx.stroke(p, with: .color(Theme.draftingGrid), lineWidth: 0.5)
    }

    private func conductor(_ ctx: inout GraphicsContext, from a: CGPoint, to b: CGPoint, color: Color, lit: Bool,
                           flow: Double, phase: Double) {
        var p = Path()
        p.move(to: a); p.addLine(to: b)
        ctx.stroke(p, with: .color(lit ? color : Theme.wire), lineWidth: lit ? 2.5 : 1.5)
        guard lit, flow != 0 else { return }
        // Energy flow: short Victron-blue dashes travelling along the conductor.
        let dash = StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [3, 9], dashPhase: CGFloat(-phase * 24 * flow))
        ctx.stroke(p, with: .color(Theme.victron), style: dash)
    }

    private func acSource(_ ctx: inout GraphicsContext, at c: CGPoint, lit: Bool, label: String, generator: Bool) {
        let r: CGFloat = 11
        let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.fill(circle, with: .color(Theme.drafting))
        ctx.stroke(circle, with: .color(lit ? Theme.victron : Theme.dcNegative), lineWidth: lit ? 2 : 1.2)
        if generator {
            ctx.draw(Text("G").font(.system(size: 11, weight: .semibold)).foregroundColor(lit ? Theme.victron : Theme.dcNegative), at: c)
        } else {
            var wave = Path()
            wave.move(to: CGPoint(x: c.x - 6, y: c.y))
            wave.addCurve(to: CGPoint(x: c.x + 6, y: c.y), control1: CGPoint(x: c.x - 2, y: c.y - 8), control2: CGPoint(x: c.x + 2, y: c.y + 8))
            ctx.stroke(wave, with: .color(lit ? Theme.victron : Theme.dcNegative), lineWidth: 1.4)
        }
        ctx.draw(Text(label).font(.diagramLabel).foregroundColor(.secondary), at: CGPoint(x: c.x, y: c.y + r + 9))
    }

    private func loadSymbol(_ ctx: inout GraphicsContext, at c: CGPoint, lit: Bool) {
        let rect = CGRect(x: c.x - 12, y: c.y - 9, width: 24, height: 18)
        let p = Path(roundedRect: rect, cornerRadius: 2)
        ctx.fill(p, with: .color(Theme.drafting))
        ctx.stroke(p, with: .color(lit ? Theme.victron : Theme.dcNegative), lineWidth: lit ? 2 : 1.2)
        var x = Path()
        x.move(to: CGPoint(x: rect.minX + 4, y: rect.minY + 4)); x.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.maxY - 4))
        x.move(to: CGPoint(x: rect.maxX - 4, y: rect.minY + 4)); x.addLine(to: CGPoint(x: rect.minX + 4, y: rect.maxY - 4))
        ctx.stroke(x, with: .color(lit ? Theme.victron : Theme.dcNegative), lineWidth: 1)
        ctx.draw(Text("AC out").font(.diagramLabel).foregroundColor(.secondary), at: CGPoint(x: c.x, y: c.y + 20))
    }

    private func batterySymbol(_ ctx: inout GraphicsContext, in r: CGRect, lit: Bool) {
        let color = lit ? Theme.victron : Theme.dcNegative
        var plates = Path()
        for i in 0..<3 {
            let x = r.minX + 8 + CGFloat(i) * 12
            plates.move(to: CGPoint(x: x, y: r.minY)); plates.addLine(to: CGPoint(x: x, y: r.maxY))
            plates.move(to: CGPoint(x: x + 5, y: r.minY + 4)); plates.addLine(to: CGPoint(x: x + 5, y: r.maxY - 4))
        }
        ctx.stroke(plates, with: .color(color), lineWidth: lit ? 2 : 1.4)
        ctx.draw(Text("Battery").font(.diagramLabel).foregroundColor(.secondary), at: CGPoint(x: r.maxX + 30, y: r.midY))
    }

    private func relaySymbol(_ ctx: inout GraphicsContext, at c: CGPoint, lit: Bool) {
        let color = lit ? Theme.victron : Theme.wire
        var p = Path()
        p.move(to: CGPoint(x: c.x - 10, y: c.y)); p.addLine(to: CGPoint(x: c.x - 3, y: c.y))
        p.move(to: CGPoint(x: c.x - 3, y: c.y)); p.addLine(to: CGPoint(x: c.x + 5, y: c.y - 6))
        p.move(to: CGPoint(x: c.x + 4, y: c.y)); p.addLine(to: CGPoint(x: c.x + 10, y: c.y))
        p.move(to: CGPoint(x: c.x, y: c.y + 2)); p.addLine(to: CGPoint(x: c.x, y: c.y + 14))
        ctx.stroke(p, with: .color(color), lineWidth: lit ? 2 : 1.2)
        if lit { ctx.draw(Text("Relay").font(.diagramLabel).foregroundColor(Theme.victron), at: CGPoint(x: c.x + 30, y: c.y)) }
    }

    private func multiBlock(_ ctx: inout GraphicsContext, in r: CGRect) {
        let block = Path(roundedRect: r, cornerRadius: 6)
        ctx.fill(block, with: .color(Theme.victron))
        // Internal symbols: transfer switch on the left, inverter/charger (~ / =) on the right.
        let inner = Color.white.opacity(0.92)
        let tsLit = lit.contains(.transferSwitch)
        var ts = Path()
        let tx = r.minX + 22
        ts.move(to: CGPoint(x: tx - 8, y: r.midY)); ts.addLine(to: CGPoint(x: tx, y: r.midY))
        ts.addLine(to: CGPoint(x: tx + 10, y: r.midY - 7))
        ts.move(to: CGPoint(x: tx + 12, y: r.midY)); ts.addLine(to: CGPoint(x: tx + 20, y: r.midY))
        ctx.stroke(ts, with: .color(inner), lineWidth: tsLit ? 2.2 : 1.2)
        let box = CGRect(x: r.maxX - 46, y: r.midY - 15, width: 30, height: 30)
        var conv = Path(roundedRect: box, cornerRadius: 2)
        conv.move(to: CGPoint(x: box.minX, y: box.maxY)); conv.addLine(to: CGPoint(x: box.maxX, y: box.minY))
        let convLit = lit.contains(.inverter) || lit.contains(.charger)
        ctx.stroke(conv, with: .color(inner), lineWidth: convLit ? 2.2 : 1.2)
        ctx.draw(Text("~").font(.system(size: 11, weight: .bold)).foregroundColor(inner), at: CGPoint(x: box.minX + 8, y: box.minY + 8))
        ctx.draw(Text("=").font(.system(size: 11, weight: .bold)).foregroundColor(inner), at: CGPoint(x: box.maxX - 8, y: box.maxY - 9))
        ctx.draw(Text(model).font(.system(size: 10, weight: .semibold)).foregroundColor(.primary),
                 at: CGPoint(x: r.minX, y: r.minY - 4), anchor: .bottomLeading)
    }
}
