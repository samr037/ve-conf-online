import SwiftUI
import VEKit

/// A numeric setting: physical value in a fixed tabular cell, unit, device range and default on hover.
struct NumberSettingRow: View {
    @ObservedObject var document: ConfigDocument
    let id: Int
    var label: String
    var unit: String?
    var help: String?

    @StateObject private var field = FieldState()

    var body: some View {
        let c = document.config
        if let info = c.info.info(id), info.isSupported {
            LabeledContent {
                HStack(spacing: 6) {
                    TextField(label, text: field.binding(current: Labels.number(info.display(c.raw(id)), step: info.step)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .font(.value)
                        .foregroundStyle(isChanged ? Theme.changed : .primary)
                        .frame(width: 84)
                        .onSubmit { commit(info) }
                        .accessibilityLabel(label)
                    Stepper(label, onIncrement: { step(info, +1) }, onDecrement: { step(info, -1) })
                        .labelsHidden()
                    Text(unit ?? "")
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .leading)
                }
            } label: {
                SettingLabel(text: label, changed: isChanged, help: help,
                             detail: "Range \(Labels.number(info.display(info.minRaw), step: info.step)) – \(Labels.number(info.display(info.maxRaw), step: info.step))\(unit.map { " " + $0 } ?? ""), default \(Labels.number(info.display(info.defaultRaw), step: info.step))")
            }
            .contextMenu { RestoreMenu(document: document, target: .setting(id), label: label) }
        }
    }

    private var isChanged: Bool { document.config.raw(id) != document.baseline.raw(id) }

    private func commit(_ info: SettingInfo) {
        defer { field.text = nil }
        guard let text = field.text else { return }
        let normalized = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let v = Double(normalized) else { NSSound.beep(); return }
        document.setValue(id, v, actionName: "Change \(label)")
    }

    private func step(_ info: SettingInfo, _ delta: Int) {
        let raw = Int(document.config.raw(id)) + delta
        guard raw >= Int(info.minRaw), raw <= Int(info.maxRaw) else { NSSound.beep(); return }
        document.setRaw(id, UInt16(raw), actionName: "Change \(label)")
    }
}

/// Text being typed in a numeric field; nil while the field shows the stored value.
final class FieldState: ObservableObject {
    @Published var text: String?
    func binding(current: String) -> Binding<String> {
        Binding(get: { self.text ?? current }, set: { self.text = $0 })
    }
}

/// A flag bit shown as a checkbox (VE Configure's TSettingCheckBox).
struct FlagToggleRow: View {
    @ObservedObject var document: ConfigDocument
    let bit: Int
    var label: String
    var inverted = false
    var help: String?

    var body: some View {
        if document.config.supportsFlag(bit) {
            Toggle(isOn: Binding(
                get: { document.config.flag(bit) != inverted },
                set: { document.setFlag(bit, $0 != inverted, actionName: "Change \(label)") }
            )) {
                SettingLabel(text: label, changed: isChanged, help: help, detail: nil)
            }
            .toggleStyle(.switch)
            .contextMenu { RestoreMenu(document: document, target: .flag(bit), label: label) }
        }
    }

    private var isChanged: Bool { document.config.flag(bit) != document.baseline.flag(bit) }
}

/// A setting with named values (VE Configure's TSettingComboBox / TSettingRadioGroup).
struct ChoiceSettingRow: View {
    @ObservedObject var document: ConfigDocument
    let id: Int
    var label: String
    var options: [(value: UInt16, title: String)]
    var help: String?

    var body: some View {
        if document.config.info.info(id)?.isSupported == true {
            Picker(selection: Binding(
                get: { document.config.raw(id) },
                set: { document.setRaw(id, $0, actionName: "Change \(label)") }
            )) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            } label: {
                SettingLabel(text: label, changed: document.config.raw(id) != document.baseline.raw(id), help: help, detail: nil)
            }
            .contextMenu { RestoreMenu(document: document, target: .setting(id), label: label) }
        }
    }
}

struct SettingLabel: View {
    var text: String
    var changed: Bool
    var help: String?
    var detail: String?

    var body: some View {
        HStack(spacing: 6) {
            // Changed marker: a short blue conductor stub, the diagram's "lit" vocabulary.
            Capsule()
                .fill(changed ? Theme.changed : .clear)
                .frame(width: 3, height: 14)
                .accessibilityHidden(true)
            Text(text)
            if changed { Text("changed").font(.caption2).foregroundStyle(Theme.changed).accessibilityHidden(false) }
        }
        .help([help, detail].compactMap { $0 }.joined(separator: "\n\n"))
    }
}

struct RestoreMenu: View {
    @ObservedObject var document: ConfigDocument
    let target: ConfigDocument.Change.Target
    let label: String

    var body: some View {
        if let change = document.changes.first(where: { $0.target == target }) {
            Button("Restore Loaded Value (\(change.before))") { document.revert(change) }
        } else {
            Button("Restore Loaded Value") {}.disabled(true)
        }
    }
}
