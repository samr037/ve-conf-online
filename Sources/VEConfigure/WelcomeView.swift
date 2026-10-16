import SwiftUI

/// First window: what this app opens and where that file comes from.
struct WelcomeView: View {
    var open: () -> Void
    var openRecent: (URL) -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                SystemDiagram(lit: [.charger, .battery], model: "MultiPlus-II", hasSecondInput: false, showsRelay: false)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.draftingGrid))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("VE Configure")
                        .font(.system(size: 26, weight: .semibold))
                    Text("Configure Victron VE.Bus inverter/chargers from your Mac: settings, grid codes, virtual switch and Assistants.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(action: open) {
                    Label("Open Configuration…", systemImage: "folder")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o", modifiers: .command)
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(width: 360)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text("Get your configuration file")
                    .font(.headline)
                Step(n: 1, text: "On VRM, open your installation, then Device list › Remote VE Configure.")
                Step(n: 2, text: "Download the .rvsc file and open it here.")
                Step(n: 3, text: "Change settings or run Assistants, then save a new file.")
                Step(n: 4, text: "Upload it on the same VRM page. The GX sends it to the inverter.")
                Spacer(minLength: 0)
                RecentFiles(openRecent: openRecent)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 640, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct Step: View {
    let n: Int
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.victron))
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RecentFiles: View {
    var openRecent: (URL) -> Void
    var body: some View {
        let recents = Array(NSDocumentController.shared.recentDocumentURLs.prefix(3))
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent").font(.caption).foregroundStyle(.secondary)
                ForEach(recents, id: \.self) { url in
                    Button(url.lastPathComponent) { openRecent(url) }
                        .buttonStyle(.link)
                }
            }
        }
    }
}
