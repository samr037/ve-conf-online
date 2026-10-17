import SwiftUI
import UniformTypeIdentifiers
import VEKit

/// The Assistants tab: what is programmed in the inverter, its answers, and the wizard to change them.
struct AssistantsPage: View {
    @ObservedObject var document: ConfigDocument
    @ObservedObject private var library = AssistantLibraryStore.shared

    var body: some View {
        AssistantsContent(document: document, model: document.assistants)
    }
}

private struct AssistantsContent: View {
    @ObservedObject var document: ConfigDocument
    @ObservedObject var model: AssistantsModel
    @StateObject private var sheet = SheetState()

    final class SheetState: ObservableObject { @Published var wizard: WizardModel? }

    var body: some View {
        Form {
            switch model.status {
            case .noLibrary: libraryMissing
            case .failed(let why): failed(why)
            case .ready:
                memory
                installedSection
                addSection
            }
        }
        .formStyle(.grouped)
        .sheet(item: $sheet.wizard) { WizardView(model: $0) }
        .alert(L("Assistants"), isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button(L("OK")) { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }

    // MARK: Sections

    private var memory: some View {
        SwiftUI.Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("Assistant memory"))
                    Spacer()
                    Text(L("%@ of %@ bytes", model.codeSize.formatted(), model.capacity.formatted()))
                        .font(.value)
                        .foregroundStyle(.secondary)
                }
                MemoryBar(used: model.codeSize, capacity: max(model.capacity, 1))
                    .frame(height: 6)
                    .accessibilityLabel(L("Assistant memory used"))
                    .accessibilityValue(L("%@ of %@ bytes", "\(model.codeSize)", "\(model.capacity)"))
            }
            .padding(.vertical, 2)
        }
    }

    private var installedSection: some View {
        SwiftUI.Section {
            if model.installed.isEmpty {
                Text(L("No assistants are programmed in this configuration."))
                    .foregroundStyle(.secondary)
            }
            ForEach(model.installed) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.headline)
                            Text(L("%@ · version %@", item.package.baseName, String(format: "%04X", item.package.id)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Configure…")) { sheet.wizard = model.wizard(for: item.id) }
                        Menu {
                            Button(L("Move Up")) { model.move(item.id, by: -1) }.disabled(item.id == 0)
                            Button(L("Move Down")) { model.move(item.id, by: 1) }.disabled(item.id == model.installed.count - 1)
                            Divider()
                            Button(L("Remove"), role: .destructive) { model.remove(item.id) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel(L("More actions for %@", item.title))
                    }
                    if !item.summary.isEmpty {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
                            ForEach(Array(item.summary.enumerated()), id: \.offset) { _, row in
                                GridRow {
                                    Text(row.label).foregroundStyle(.secondary)
                                    Text(row.value).font(.callout.monospacedDigit())
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text(L("Installed"))
        } footer: {
            Text(L("Assistants run in this order inside the inverter. Changing one re-programs all of them; review the change list before saving."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var addSection: some View {
        SwiftUI.Section {
            Menu {
                ForEach(model.available, id: \.package.id) { entry in
                    Button(entry.title) { sheet.wizard = model.wizard(for: nil, adding: entry.package) }
                }
            } label: {
                Label(L("Add Assistant…"), systemImage: "plus")
            }
            .fixedSize()
        }
    }

    private var libraryMissing: some View {
        SwiftUI.Section {
            VStack(alignment: .leading, spacing: 10) {
                Label(L("Victron's assistant library is needed"), systemImage: "books.vertical")
                    .font(.headline)
                Text(L("Assistants are Victron's programs. Import the library file (all112.vfp or newer) from a VE Configure installation, under “VE Configure tools/Assistants”. The app copies it once to its support folder."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Import Assistant Library…")) { importLibrary() }
            }
            .padding(.vertical, 4)
        }
    }

    private func failed(_ why: String) -> some View {
        SwiftUI.Section {
            Label(why, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
            Text(L("The installed library cannot read back the assistant program in this file. You can still change settings on the other pages; the program is kept unchanged."))
                .foregroundStyle(.secondary)
        }
    }

    private func importLibrary() {
        let panel = NSOpenPanel()
        // Any file: a copied library may have lost its extension. It is installed only if it parses.
        panel.allowedContentTypes = [.data]
        panel.message = L("Choose allNNN.vfp from “VE Configure tools/Assistants”.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try AssistantLibraryStore.shared.importLibrary(from: url) } catch { NSAlert(error: error).runModal() }
    }
}

/// Memory budget, counted to the byte like a tape side: blue fill, warning colour past 90 %.
private struct MemoryBar: View {
    var used: Int
    var capacity: Int
    var body: some View {
        GeometryReader { g in
            let f = min(1, Double(used) / Double(capacity))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.draftingGrid)
                Capsule().fill(f > 0.9 ? Theme.warning : Theme.victron).frame(width: g.size.width * f)
            }
        }
    }
}
