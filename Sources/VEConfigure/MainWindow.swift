import SwiftUI
import VEKit

/// The seven VE Configure tabs, in VE Configure's order.
enum Section: String, CaseIterable, Identifiable, Hashable {
    case general, grid, inverter, charger, virtualSwitch, assistants, advanced
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L("General")
        case .grid: L("Grid")
        case .inverter: L("Inverter")
        case .charger: L("Charger")
        case .virtualSwitch: L("Virtual Switch")
        case .assistants: L("Assistants")
        case .advanced: L("Advanced")
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .grid: "bolt.horizontal"
        case .inverter: "waveform.path"
        case .charger: "battery.100percent.bolt"
        case .virtualSwitch: "switch.2"
        case .assistants: "wand.and.stars"
        case .advanced: "gearshape.2"
        }
    }

    /// What each tab governs in the installation; the diagram lights these parts.
    var lit: Set<DiagramPart> {
        switch self {
        case .general: [.acIn, .acIn2, .transferSwitch, .battery]
        case .grid: [.acIn, .feedIn, .transferSwitch]
        case .inverter: [.inverter, .dcBus, .acOut]
        case .charger: [.charger, .battery]
        case .virtualSwitch: [.relay]
        case .assistants: [.acIn, .feedIn, .battery, .relay]
        case .advanced: [.charger, .acIn]
        }
    }
}

final class WindowState: ObservableObject {
    @Published var section: Section? = .general
    @Published var showsChanges = true
    /// Selected sub-page per tab (Grid: grid-code page; Virtual switch: its five sheets).
    @Published var subpage: [Section: String] = [:]
    /// What the diagram lights. Observed only by the diagram, so hovering does not re-render the form.
    let focus = DiagramFocus()
}

/// The diagram follows the group under the pointer; otherwise it shows the page's parts.
final class DiagramFocus: ObservableObject {
    @Published var hovered: Set<DiagramPart>?
    @Published var page: Set<DiagramPart> = []
}

private struct FocusedDiagram: View {
    @ObservedObject var focus: DiagramFocus
    @ObservedObject var document: ConfigDocument
    var fallback: Set<DiagramPart>

    var body: some View {
        let c = document.config
        SystemDiagram(lit: focus.hovered ?? (focus.page.isEmpty ? fallback : focus.page), model: c.modelName,
                      hasSecondInput: c.hasSecondACInput, annotations: annotations)
    }

    /// Key values written on the conductor they govern: AC-in limit, AC-out voltage, absorption/float voltages.
    private var annotations: [DiagramPart: DiagramAnnotation] {
        let c = document.config, b = document.baseline
        func text(_ id: Int, _ unit: String) -> String? {
            guard let info = c.info.info(id), info.isSupported else { return nil }
            return Labels.number(info.display(c.raw(id)), step: info.step) + " " + unit
        }
        var out: [DiagramPart: DiagramAnnotation] = [:]
        if let t = text(6, "A") { out[.acIn] = .init(text: t, changed: c.raw(6) != b.raw(6)) }
        if let t = text(5, "V") { out[.acOut] = .init(text: t, changed: c.raw(5) != b.raw(5)) }
        if let abs = text(2, "V"), let float = text(3, "V") {
            out[.battery] = .init(text: L("Absorption %@ · Float %@", abs, float), changed: c.raw(2) != b.raw(2) || c.raw(3) != b.raw(3))
        }
        return out
    }
}

struct MainWindow: View {
    @ObservedObject var document: ConfigDocument
    @ObservedObject var state: WindowState
    var save: () -> Void

    var body: some View {
        NavigationSplitView {
            Sidebar(document: document, selection: $state.section)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            let section = state.section ?? .general
            VStack(spacing: 0) {
                FocusedDiagram(focus: state.focus, document: document, fallback: section.lit)
                Divider()
                SectionView(section: section, document: document, state: state)
            }
            .navigationTitle(section.title)
            .navigationSubtitle(document.title)
            .inspector(isPresented: $state.showsChanges) {
                ChangeList(document: document, save: save)
                    .inspectorColumnWidth(min: 240, ideal: 270, max: 360)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { state.showsChanges.toggle() } label: {
                        Label(L("Changes"), systemImage: "list.bullet.rectangle")
                    }
                    .help(L("Show or hide the list of changes"))
                }
            }
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var document: ConfigDocument
    @Binding var selection: Section?

    var body: some View {
        List(selection: $selection) {
            SwiftUI.Section {
                ForEach(Section.allCases) { s in
                    Label(s.title, systemImage: s.symbol).tag(s)
                }
            } header: {
                DeviceIdentity(config: document.config)
            }
        }
        .listStyle(.sidebar)
    }
}

private struct DeviceIdentity: View {
    let config: DeviceConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(config.modelName)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(L("Serial %@", config.serial ?? "—"))
            Text(L("Firmware %@", config.firmware.description))
            if let date = config.readDate {
                Text(L("Read %@", date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: L10n.language)))))
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .textCase(nil)
        .padding(.bottom, 8)
    }
}

extension DeviceConfiguration {
    /// Best-effort product name from the firmware type until the device table is decoded.
    var modelName: String {
        let r = MetaGenerator.ratings(self)
        guard r.dc > 0, r.power > 0 else { return L("VE.Bus inverter/charger") }
        return "\(r.dc) V · \(r.power) VA"
    }
    var hasSecondACInput: Bool { info.info(49)?.isSupported == true }
}
