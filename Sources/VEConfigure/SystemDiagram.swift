import SwiftUI

/// Parts of the installation a setting can act on. A page lights the parts it governs.
enum DiagramPart: String, CaseIterable, Hashable, Codable {
    case acIn, acIn2, transferSwitch, inverter, charger, acOut, dcBus, battery, relay, feedIn, generator
}

/// A value written on the conductor it governs (e.g. "32 A" on AC-in). `changed` draws it in Victron blue.
struct DiagramAnnotation: Equatable {
    var text: String
    var changed: Bool
}

/// The user's installation drawn as a single-line diagram, in the style of Victron's manuals.
/// AC source(s) on the left, the Multi in the centre, loads on the right, the battery below.
///
/// Colour jobs: a lit conductor keeps its IEC colour at full weight (AC line brown with its neutral blue,
/// DC+ red, DC− black); unlit conductors are grey. Energy flow is a lighter tint of the conductor's own colour.
/// Victron blue belongs to the product block, lit symbols and changed values only.
/// PV is not drawn: a .rvsc carries no evidence of PV inverters, and the diagram never invents equipment.
struct SystemDiagram: View {
    var lit: Set<DiagramPart>
    var model: String
    var hasSecondInput: Bool
    var showsRelay: Bool = true
    var annotations: [DiagramPart: DiagramAnnotation] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !hasFlow)) { context in
            Canvas { ctx, size in
                draw(in: &ctx, size: size, phase: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(height: 132)
        .background(Theme.drafting)
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    private var hasFlow: Bool { !lit.isDisjoint(with: [.charger, .inverter, .feedIn]) }

    private var accessibilitySummary: String {
        let names = lit.map(\.rawValue).sorted().joined(separator: ", ")
        var s = L("System diagram of the %@. Highlighted: %@.", model, names.isEmpty ? L("none") : names)
        let values = annotations.values.map(\.text).joined(separator: ", ")
        if !values.isEmpty { s += " " + values }
        return s
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

        // AC-in 1 (or the single AC input).
        let in1Lit = !lit.isDisjoint(with: [.acIn, .charger, .feedIn, .transferSwitch])
        acSource(&ctx, at: acIn1, lit: in1Lit, label: hasSecondInput ? L("AC-in 1") : L("AC in"), generator: false)
        acPair(&ctx, from: CGPoint(x: acIn1.x + 12, y: acIn1.y), to: CGPoint(x: multi.minX, y: acIn1.y), lit: in1Lit,
               flow: lit.contains(.feedIn) ? -1 : lit.contains(.charger) ? 1 : 0, phase: phase)
        annotate(&ctx, .acIn, at: CGPoint(x: (acIn1.x + multi.minX) / 2, y: acIn1.y - 11))
        if hasSecondInput {
            let in2Lit = !lit.isDisjoint(with: [.acIn2, .generator])
            acSource(&ctx, at: acIn2, lit: in2Lit, label: L("AC-in 2"), generator: true)
            acPair(&ctx, from: CGPoint(x: acIn2.x + 12, y: acIn2.y), to: CGPoint(x: multi.minX, y: acIn2.y), lit: in2Lit, flow: 0, phase: phase)
        }

        // AC-out to the loads.
        let outLit = lit.contains(.acOut) || lit.contains(.inverter)
        acPair(&ctx, from: CGPoint(x: multi.maxX, y: midY), to: CGPoint(x: load.x - 12, y: midY), lit: outLit,
               flow: lit.contains(.inverter) ? 1 : 0, phase: phase)
        loadSymbol(&ctx, at: load, lit: outLit)
        annotate(&ctx, .acOut, at: CGPoint(x: (multi.maxX + load.x) / 2, y: midY - 11))

        // DC: positive (red) and negative (black) to the battery.
        let dcLit = !lit.isDisjoint(with: [.dcBus, .battery, .charger, .inverter])
        let dcFlow: Double = lit.contains(.charger) ? 1 : (lit.contains(.inverter) || lit.contains(.feedIn)) ? -1 : 0
        conductor(&ctx, from: CGPoint(x: multi.midX - 10, y: multi.maxY), to: CGPoint(x: multi.midX - 10, y: battery.minY),
                  color: Theme.dcPositive, lit: dcLit, flow: dcFlow, phase: phase)
        conductor(&ctx, from: CGPoint(x: multi.midX + 10, y: battery.minY), to: CGPoint(x: multi.midX + 10, y: multi.maxY),
                  color: Theme.dcNegative, lit: dcLit, flow: dcFlow, phase: phase)
        batterySymbol(&ctx, in: battery, lit: lit.contains(.battery) || lit.contains(.charger))
        // Against the DC pair, left of the red conductor, halfway down.
        annotate(&ctx, .battery, at: CGPoint(x: multi.midX - 18, y: (multi.maxY + battery.minY) / 2), anchor: .trailing)

        multiBlock(&ctx, in: multi)
        // Terminal dots where conductors land on the Multi.
        for p in [CGPoint(x: multi.minX, y: acIn1.y), CGPoint(x: multi.maxX, y: midY),
                  CGPoint(x: multi.midX - 10, y: multi.maxY), CGPoint(x: multi.midX + 10, y: multi.maxY)]
            + (hasSecondInput ? [CGPoint(x: multi.minX, y: acIn2.y)] : []) {
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(Theme.dcNegative))
        }
        if showsRelay { relaySymbol(&ctx, at: CGPoint(x: multi.maxX - 18, y: multi.minY - 14), lit: lit.contains(.relay)) }
    }

    private func drawGrid(_ ctx: inout GraphicsContext, _ size: CGSize) {
        var p = Path()
        stride(from: 0, through: size.width, by: 16).forEach { p.move(to: CGPoint(x: $0, y: 0)); p.addLine(to: CGPoint(x: $0, y: size.height)) }
        stride(from: 0, through: size.height, by: 16).forEach { p.move(to: CGPoint(x: 0, y: $0)); p.addLine(to: CGPoint(x: size.width, y: $0)) }
        ctx.stroke(p, with: .color(Theme.draftingGrid), lineWidth: 0.5)
    }

    /// AC is a line + neutral pair: brown line on top, blue neutral 3 pt below.
    private func acPair(_ ctx: inout GraphicsContext, from a: CGPoint, to b: CGPoint, lit: Bool, flow: Double, phase: Double) {
        conductor(&ctx, from: a, to: b, color: Theme.acLine, lit: lit, flow: flow, phase: phase)
        let off = CGFloat(3.5)
        conductor(&ctx, from: CGPoint(x: a.x, y: a.y + off), to: CGPoint(x: b.x, y: b.y + off), color: Theme.acNeutral, lit: lit,
                  flow: 0, phase: phase, weight: 1.2)
    }

    private func conductor(_ ctx: inout GraphicsContext, from a: CGPoint, to b: CGPoint, color: Color, lit: Bool,
                           flow: Double, phase: Double, weight: CGFloat = 2.5) {
        var p = Path()
        p.move(to: a); p.addLine(to: b)
        guard lit else {
            ctx.stroke(p, with: .color(Theme.wire), lineWidth: 1.2)
            return
        }
        guard flow != 0 else {
            ctx.stroke(p, with: .color(color), lineWidth: weight)
            return
        }
        // Energy flow: the conductor at a lighter tint, its own colour travelling along it.
        ctx.stroke(p, with: .color(color.opacity(0.4)), lineWidth: weight)
        let dash = StrokeStyle(lineWidth: weight, lineCap: .round, dash: [6, 6], dashPhase: CGFloat(-phase * 24 * flow))
        ctx.stroke(p, with: .color(color), style: dash)
    }

    private func annotate(_ ctx: inout GraphicsContext, _ part: DiagramPart, at p: CGPoint, anchor: UnitPoint = .center) {
        guard let a = annotations[part] else { return }
        let text = Text(a.text).font(.system(size: 10, weight: a.changed ? .semibold : .medium).monospacedDigit())
            .foregroundColor(a.changed ? Theme.changed : .secondary)
        ctx.draw(text, at: p, anchor: anchor)
    }

    private func acSource(_ ctx: inout GraphicsContext, at c: CGPoint, lit: Bool, label: String, generator: Bool) {
        let r: CGFloat = 11
        let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        let ink = lit ? Theme.dcNegative : Theme.wire
        ctx.fill(circle, with: .color(Theme.drafting))
        ctx.stroke(circle, with: .color(ink), lineWidth: lit ? 1.8 : 1.2)
        if generator {
            ctx.draw(Text("G").font(.system(size: 11, weight: .semibold)).foregroundColor(ink), at: c)
        } else {
            var wave = Path()
            wave.move(to: CGPoint(x: c.x - 6, y: c.y))
            wave.addCurve(to: CGPoint(x: c.x + 6, y: c.y), control1: CGPoint(x: c.x - 2, y: c.y - 8), control2: CGPoint(x: c.x + 2, y: c.y + 8))
            ctx.stroke(wave, with: .color(ink), lineWidth: 1.4)
        }
        ctx.draw(Text(label).font(.diagramLabel).foregroundColor(.secondary), at: CGPoint(x: c.x, y: c.y + r + 10))
    }

    private func loadSymbol(_ ctx: inout GraphicsContext, at c: CGPoint, lit: Bool) {
        let rect = CGRect(x: c.x - 12, y: c.y - 9, width: 24, height: 18)
        let p = Path(roundedRect: rect, cornerRadius: 2)
        let ink = lit ? Theme.dcNegative : Theme.wire
        ctx.fill(p, with: .color(Theme.drafting))
        ctx.stroke(p, with: .color(ink), lineWidth: lit ? 1.8 : 1.2)
        var x = Path()
        x.move(to: CGPoint(x: rect.minX + 4, y: rect.minY + 4)); x.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.maxY - 4))
        x.move(to: CGPoint(x: rect.maxX - 4, y: rect.minY + 4)); x.addLine(to: CGPoint(x: rect.minX + 4, y: rect.maxY - 4))
        ctx.stroke(x, with: .color(ink), lineWidth: 1)
        ctx.draw(Text(L("AC out")).font(.diagramLabel).foregroundColor(.secondary), at: CGPoint(x: c.x, y: c.y + 21))
    }

    private func batterySymbol(_ ctx: inout GraphicsContext, in r: CGRect, lit: Bool) {
        let ink = lit ? Theme.dcNegative : Theme.wire
        var long = Path(), short = Path()
        for i in 0..<3 {
            let x = r.minX + 8 + CGFloat(i) * 12
            long.move(to: CGPoint(x: x, y: r.minY)); long.addLine(to: CGPoint(x: x, y: r.maxY))
            short.move(to: CGPoint(x: x + 5, y: r.minY + 4)); short.addLine(to: CGPoint(x: x + 5, y: r.maxY - 4))
        }
        ctx.stroke(long, with: .color(ink), lineWidth: lit ? 2 : 1.4)
        ctx.stroke(short, with: .color(ink), lineWidth: lit ? 3 : 2)
        ctx.draw(Text(L("Battery")).font(.diagramLabel).foregroundColor(.secondary), at: CGPoint(x: r.maxX + 30, y: r.midY))
    }

    private func relaySymbol(_ ctx: inout GraphicsContext, at c: CGPoint, lit: Bool) {
        let color = lit ? Theme.victron : Theme.wire
        var p = Path()
        p.move(to: CGPoint(x: c.x - 10, y: c.y)); p.addLine(to: CGPoint(x: c.x - 3, y: c.y))
        p.move(to: CGPoint(x: c.x - 3, y: c.y)); p.addLine(to: CGPoint(x: c.x + 5, y: c.y - 6))
        p.move(to: CGPoint(x: c.x + 4, y: c.y)); p.addLine(to: CGPoint(x: c.x + 10, y: c.y))
        p.move(to: CGPoint(x: c.x, y: c.y + 2)); p.addLine(to: CGPoint(x: c.x, y: c.y + 14))
        ctx.stroke(p, with: .color(color), lineWidth: lit ? 2 : 1.2)
        if lit { ctx.draw(Text(L("Relay")).font(.diagramLabel).foregroundColor(Theme.victron), at: CGPoint(x: c.x + 30, y: c.y)) }
    }

    private func multiBlock(_ ctx: inout GraphicsContext, in r: CGRect) {
        let block = Path(roundedRect: r, cornerRadius: 6)
        ctx.fill(block, with: .color(Theme.victronBlock))
        // Internal symbols: transfer switch on the left, inverter/charger (~ / =) on the right.
        let inner = Color.white
        let tsLit = lit.contains(.transferSwitch)
        var ts = Path()
        let tx = r.minX + 22
        ts.move(to: CGPoint(x: tx - 8, y: r.midY)); ts.addLine(to: CGPoint(x: tx, y: r.midY))
        ts.addLine(to: CGPoint(x: tx + 10, y: r.midY - 7))
        ts.move(to: CGPoint(x: tx + 12, y: r.midY)); ts.addLine(to: CGPoint(x: tx + 20, y: r.midY))
        ctx.stroke(ts, with: .color(inner), lineWidth: tsLit ? 2.2 : 1.4)
        let box = CGRect(x: r.maxX - 46, y: r.midY - 15, width: 30, height: 30)
        var conv = Path(roundedRect: box, cornerRadius: 2)
        conv.move(to: CGPoint(x: box.minX, y: box.maxY)); conv.addLine(to: CGPoint(x: box.maxX, y: box.minY))
        let convLit = lit.contains(.inverter) || lit.contains(.charger)
        ctx.stroke(conv, with: .color(inner), lineWidth: convLit ? 2.2 : 1.4)
        ctx.draw(Text("~").font(.system(size: 11, weight: .bold)).foregroundColor(inner), at: CGPoint(x: box.minX + 8, y: box.minY + 8))
        ctx.draw(Text("=").font(.system(size: 11, weight: .bold)).foregroundColor(inner), at: CGPoint(x: box.maxX - 8, y: box.maxY - 9))
        ctx.draw(Text(model).font(.system(size: 10, weight: .semibold)).foregroundColor(.primary),
                 at: CGPoint(x: r.minX, y: r.minY - 4), anchor: .bottomLeading)
    }
}
