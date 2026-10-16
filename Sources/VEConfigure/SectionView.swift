import SwiftUI
import VEKit

/// One tab's content. Provisional hand-written groups until the generated catalog drives every page.
struct SectionView: View {
    let section: Section
    @ObservedObject var document: ConfigDocument

    var body: some View {
        Form {
            switch section {
            case .general:
                SwiftUI.Section("AC input") {
                    NumberSettingRow(document: document, id: 6, label: "AC-in current limit", unit: "A")
                    NumberSettingRow(document: document, id: 49, label: "AC-in 2 current limit", unit: "A")
                }
                SwiftUI.Section("Battery monitor") {
                    NumberSettingRow(document: document, id: 64, label: "Battery capacity", unit: "Ah")
                    NumberSettingRow(document: document, id: 65, label: "State of charge when bulk finished", unit: "%")
                    NumberSettingRow(document: document, id: 72, label: "Charge efficiency", unit: nil)
                }
            case .charger:
                SwiftUI.Section("Charge curve") {
                    FlagToggleRow(document: document, bit: 36, label: "Lithium batteries")
                    ChoiceSettingRow(document: document, id: 10, label: "Charge curve",
                                     options: [(1, "Fixed"), (2, "Adaptive"), (3, "Adaptive + BatterySafe")])
                    NumberSettingRow(document: document, id: 2, label: "Absorption voltage", unit: "V")
                    NumberSettingRow(document: document, id: 3, label: "Float voltage", unit: "V")
                    NumberSettingRow(document: document, id: 4, label: "Charge current", unit: "A")
                    NumberSettingRow(document: document, id: 9, label: "Maximum absorption time", unit: "min")
                }
            case .inverter:
                SwiftUI.Section("DC input") {
                    NumberSettingRow(document: document, id: 11, label: "DC input low shut-down", unit: "V")
                    NumberSettingRow(document: document, id: 12, label: "DC input low restart margin", unit: "V")
                }
                SwiftUI.Section("Output") {
                    NumberSettingRow(document: document, id: 5, label: "Inverter output voltage", unit: "V")
                    FlagToggleRow(document: document, bit: 5, label: "PowerAssist")
                }
            default:
                Text("This page arrives with the generated catalog.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
