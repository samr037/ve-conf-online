import SwiftUI
import VEKit

/// The seven VE Configure tabs, in VE Configure's order.
enum Section: String, CaseIterable, Identifiable, Hashable {
    case general, grid, inverter, charger, virtualSwitch, assistants, advanced
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .grid: "Grid"
        case .inverter: "Inverter"
        case .charger: "Charger"
        case .virtualSwitch: "Virtual Switch"
        case .assistants: "Assistants"
        case .advanced: "Advanced"
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
                SystemDiagram(lit: section.lit, model: document.config.modelName,
                              hasSecondInput: document.config.hasSecondACInput)
                Divider()
                SectionView(section: section, document: document)
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
                        Label("Changes", systemImage: "list.bullet.rectangle")
                    }
                    .help("Show or hide the list of changes")
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
            Text("Serial \(config.serial ?? "—")")
            Text("Firmware \(config.firmware.description)")
            if let date = config.readDate {
                Text("Read \(date.formatted(date: .abbreviated, time: .shortened))")
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
    var modelName: String { "VE.Bus device" }
    var hasSecondACInput: Bool { info.info(49)?.isSupported == true }
}
