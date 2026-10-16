import SwiftUI
import VEKit

/// Trailing inspector: every difference from the loaded file, revertible one by one, and the save action.
struct ChangeList: View {
    @ObservedObject var document: ConfigDocument
    var save: () -> Void

    var body: some View {
        let changes = document.changes
        VStack(alignment: .leading, spacing: 0) {
            header(count: changes.count)
            Divider()
            if changes.isEmpty {
                empty
            } else {
                List {
                    ForEach(changes) { change in
                        row(change)
                            .contextMenu {
                                Button(L("Restore Loaded Value")) { document.revert(change) }
                                    .disabled(change.target == .assistants)
                            }
                    }
                }
                .listStyle(.sidebar)
            }
            Divider()
            footer
        }
        .frame(minWidth: 240)
    }

    private func header(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L("Changes")).font(.headline)
            Spacer()
            Text(count == 0 ? L("None") : "\(count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(count == 0 ? Color.secondary : Theme.changed)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Spacer()
            Text(L("No changes yet"))
                .font(.callout.weight(.medium))
            Text(L("Every setting you change appears here with its previous value, so you can review it before saving."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 200)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ c: ConfigDocument.Change) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(c.label).font(.callout)
            HStack(spacing: 6) {
                if !c.before.isEmpty {
                    Text(c.before).strikethrough().foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                        .accessibilityLabel(L("changed to"))
                }
                Text(c.after).foregroundStyle(Theme.changed).fontWeight(.medium)
            }
            .font(.caption.monospacedDigit())
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Upload the saved file through VRM (Remote VE Configure). The GX resets the inverter if needed."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = document.saveBlockReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Enabled while blocked so the attempt explains why (the save path shows saveBlockReason).
            Button(action: save) {
                Text(L("Save…")).frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!document.canSave && document.saveBlockReason == nil)
        }
        .padding(14)
    }
}
