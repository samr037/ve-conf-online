import AppKit
import Combine
import VEKit

/// Victron's assistant library (`allNNN.vfp`). Not redistributed: imported once from a VE Configure install.
final class AssistantLibraryStore: ObservableObject {
    static let shared = AssistantLibraryStore()
    @Published private(set) var library: AssistantLibrary?
    @Published private(set) var fileName: String?

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VE Configure", isDirectory: true)
    }

    private init() { load() }

    func load() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        let vfp = files.filter { $0.pathExtension.lowercased() == "vfp" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let latest = vfp.last, let lib = try? AssistantLibrary(contentsOf: latest) else { library = nil; return }
        library = lib
        fileName = latest.lastPathComponent
    }

    /// Copies a user-chosen `allNNN.vfp` into Application Support.
    func importLibrary(from url: URL) throws {
        _ = try AssistantLibrary(contentsOf: url)   // validate first
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let dest = Self.folder.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: url, to: dest)
        load()
    }

    static var languages: [String] {
        [L10n.language] + Locale.preferredLanguages.map { String($0.prefix(2)).lowercased() } + ["en"]
    }
}

/// The assistants programmed in one configuration: reconstruction, editing and re-programming.
final class AssistantsModel: ObservableObject {
    enum Status: Equatable { case noLibrary, ready, failed(String) }

    struct Installed: Identifiable {
        let id: Int           // position in the composer
        let package: AssistantPackage
        var title: String
        var summary: [(label: String, value: String)]
    }

    @Published private(set) var status: Status = .noLibrary
    @Published private(set) var installed: [Installed] = []
    @Published private(set) var codeSize = 0
    @Published var message: String?

    private unowned let document: ConfigDocument
    private var composer: AssistantComposer?
    private var lastImage: [UInt8] = []
    private var cancellables: Set<AnyCancellable> = []

    var memorySize: Int { document.config.data.assistantMemory.count }
    /// Bytes the code may use: the area minus the ID directory (framework + assistants) and the checksum.
    var capacity: Int { memorySize - 4 - 2 * (installed.count + 2) }

    init(document: ConfigDocument) {
        self.document = document
        reload()
        document.$config
            .map(\.data.assistantMemory)
            .removeDuplicates()
            .sink { [weak self] mem in
                guard let self, mem != self.lastImage else { return }
                self.reload()   // undo / redo / file reload
            }
            .store(in: &cancellables)
        AssistantLibraryStore.shared.$library.dropFirst().sink { [weak self] _ in self?.reload() }.store(in: &cancellables)
    }

    func reload() {
        let config = document.config
        lastImage = config.data.assistantMemory
        guard let lib = AssistantLibraryStore.shared.library else { status = .noLibrary; installed = []; return }
        do {
            let c = try AssistantComposer(library: lib)
            c.languages = AssistantLibraryStore.languages
            c.meta = MetaGenerator.source(for: config)
            if config.data.assistantMemory.allSatisfy({ $0 == 0xFF }) || AssistantComposer.installedIDs(in: config.data.assistantMemory).count < 2 {
                c.items = []
                composer = c
                codeSize = 0
                installed = []
                status = .ready
                return
            }
            let r = try c.reconstruct(image: config.data.assistantMemory)
            guard r.success else {
                status = .failed(r.messages.first { $0.kind == .error || $0.kind == .fatal }?.text ?? L("The assistant program could not be read back."))
                composer = nil
                installed = []
                return
            }
            composer = c
            let b = c.build()
            codeSize = b.code.count
            installed = describe(c, steps: b.steps)
            status = .ready
        } catch {
            status = .failed("\(error)")
        }
    }

    /// Assistants available to add (framework excluded), with their menu titles.
    var available: [(package: AssistantPackage, title: String)] {
        guard let lib = AssistantLibraryStore.shared.library else { return [] }
        return lib.latest.filter { !["asfStart", "asfStop"].contains($0.baseName) }
            .map { ($0, Self.title(of: $0)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func title(of p: AssistantPackage) -> String {
        guard let script = p.script(preferring: AssistantLibraryStore.languages) else { return p.baseName }
        let menu = WizardText(script.bytes).lines("MenuInfo") ?? []
        if menu.count >= 2 { return WizardStepContent.plain(menu[1]) }
        if let first = menu.first { return WizardStepContent.plain(first.components(separatedBy: "->").last ?? first) }
        return p.baseName
    }

    static func blurb(of p: AssistantPackage) -> String {
        guard let script = p.script(preferring: AssistantLibraryStore.languages) else { return "" }
        let menu = WizardText(script.bytes).lines("MenuInfo") ?? []
        return menu.dropFirst(2).map { WizardStepContent.plain($0) }.joined(separator: " ")
    }

    private func describe(_ c: AssistantComposer, steps: [AssistantStepPresentation]) -> [Installed] {
        stepCounts = Dictionary(grouping: steps, by: \.assistant).mapValues(\.count)
        return c.items.enumerated().map { i, item in
            let script = item.package.script(preferring: AssistantLibraryStore.languages).map { WizardText($0.bytes) }
            var summary: [(String, String)] = []
            for p in steps where p.assistant == item.name && p.step.inSummary {
                let content = WizardStepContent(step: p.step, text: script, format: p.format)
                summary.append((content.title, Self.tidy(Self.answerText(p, content))))
            }
            return Installed(id: i, package: item.package, title: Self.title(of: item.package), summary: summary)
        }
    }

    /// Victron lays summaries out with tabs (`\TI\`): one tab-separated cell per line, "-" cells become bullets.
    static func tidy(_ s: String) -> String {
        var cells: [String] = []
        for raw in s.components(separatedBy: "\n") {
            for cell in raw.components(separatedBy: "\t") {
                let c = cell.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
                if !c.isEmpty { cells.append(c) }
            }
        }
        var out: [String] = []
        var bulletNext = false
        for var c in cells {
            if c == "-" || c == "•" { bulletNext = true; continue }
            // Inline lists "a: - b - c" become one bullet per item.
            let parts = c.components(separatedBy: " - ")
            if parts.count > 1 {
                if !parts[0].isEmpty { out.append(parts[0].hasPrefix("- ") ? "• " + parts[0].dropFirst(2) : parts[0]) }
                out += parts.dropFirst().map { "• " + $0 }
                bulletNext = false
                continue
            }
            if c.hasPrefix("- ") { c = "• " + c.dropFirst(2) }
            if bulletNext { c = "• " + c; bulletNext = false }
            // "0.25 C" + "= 46,00 V" and "label:" + value belong on one line.
            if let last = out.last, c.hasPrefix("=") || last.hasSuffix("=") {
                out[out.count - 1] = last + " " + c
            } else {
                out.append(c)
            }
        }
        return out.joined(separator: "\n")
    }

    /// Steps of each assistant in the last build (for the wizard's "Step n of N").
    private(set) var stepCounts: [String: Int] = [:]

    static func answerText(_ p: AssistantStepPresentation, _ content: WizardStepContent) -> String {
        func lineText(_ l: [WizardLine]) -> String { l.first.map { $0.runs.map(\.text).joined() } ?? "" }
        switch p.step.kind {
        case .radio:
            let v = Int(p.values.first ?? 0)
            return v < content.options.count ? lineText(content.options[v]) : "\(v)"
        case .check:
            let mask = p.values.first ?? 0
            let on = content.options.indices.filter { mask >> $0 & 1 == 1 }.map { lineText(content.options[$0]) }
            return on.isEmpty ? L("None") : on.joined(separator: ", ")
        case .entry:
            return content.entry.map { pieces in
                pieces.map { piece -> String in
                    switch piece {
                    case .text(let runs): return runs.map(\.text).joined()
                    case .field(let i, let items):
                        guard i < p.values.count, i < p.step.fields.count else { return "?" }
                        let v = p.values[i]
                        if let items { let k = Int(v - p.step.fields[i].min); return k >= 0 && k < items.count ? items[k] : "\(v)" }
                        return p.step.fields[i].display(v)
                    }
                }.joined()
            }.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: Editing

    /// Starts the wizard of an installed assistant, or of a new one appended to the list.
    func wizard(for index: Int?, adding package: AssistantPackage? = nil) -> WizardModel? {
        guard let c = composer else { return nil }
        let snapshot = (c.items, c.answers)
        if let package {
            guard !c.items.contains(where: { $0.name == package.baseName }) else {
                message = L("%@ is already installed. Use Configure to change it.", Self.title(of: package))
                return nil
            }
            c.items.append(.init(package: package))
        }
        guard let name = index.map({ c.items[$0].name }) ?? package?.baseName else { return nil }
        let title = package.map(Self.title(of:)) ?? installed.first { $0.id == index }?.title ?? name
        return WizardModel(composer: c, assistant: name, title: title, languages: AssistantLibraryStore.languages,
                           expectedSteps: package == nil ? stepCounts[name] : nil) { [weak self] result in
            guard let self else { return }
            guard let result else { (c.items, c.answers) = snapshot; return }
            self.program(actionName: package != nil ? L("Add %@", title) : L("Configure %@", title), wizardChanges: result.vecChanges) {
                (c.items, c.answers) = snapshot
            }
        }
    }

    func remove(_ index: Int) {
        guard let c = composer, index < c.items.count else { return }
        let snapshot = (c.items, c.answers)
        let name = installed.first { $0.id == index }?.title ?? c.items[index].name
        c.items.remove(at: index)
        program(actionName: L("Remove %@", name)) { (c.items, c.answers) = snapshot }
    }

    func move(_ index: Int, by delta: Int) {
        guard let c = composer, index + delta >= 0, index + delta < c.items.count else { return }
        let snapshot = (c.items, c.answers)
        c.items.swapAt(index, index + delta)
        program(actionName: L("Reorder Assistants")) { (c.items, c.answers) = snapshot }
    }

    /// Re-assembles everything and writes the program (and assistant-made setting changes) into the document.
    private func program(actionName: String, wizardChanges: [String: Value] = [:], rollback: () -> Void) {
        guard let c = composer else { return }
        let r = c.build()
        guard r.success else {
            rollback()
            message = r.messages.first { $0.kind == .error || $0.kind == .fatal }.map(Self.clean) ?? L("The assistants could not be assembled.")
            return
        }
        let needed = r.code.count + 4 + 2 * (c.items.count + 2)
        guard c.items.isEmpty || needed <= memorySize else {
            rollback()
            message = L("Not enough assistant memory: %@ bytes needed, %@ available.", "\(needed)", "\(memorySize)")
            return
        }
        let (new, battery) = c.apply(r, to: document.config, extraChanges: wizardChanges)
        lastImage = new.data.assistantMemory
        document.replace(with: new, actionName: actionName)
        if let battery, battery > 0 { message = L("The assistant selected battery preset %@. Check the Charger page.", "\(battery)") }
        codeSize = c.items.isEmpty ? 0 : r.code.count
        installed = describe(c, steps: r.steps)
        let notes = r.messages.filter { $0.kind == .message }.map(Self.clean)
        if !notes.isEmpty && message == nil { message = notes.joined(separator: "\n") }
    }

    static func clean(_ m: AssemblerMessage) -> String {
        var t = m.text
        if t.hasPrefix("'") && t.hasSuffix("'") && t.count >= 2 { t = String(t.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        return t
    }
}
