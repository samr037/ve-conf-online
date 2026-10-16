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

    /// Number in a library file name (`all112.vfp` → 112); 0 when it has none.
    static func version(of url: URL) -> Int {
        url.deletingPathExtension().lastPathComponent.split { !$0.isNumber }.first.flatMap { Int($0) } ?? 0
    }

    /// Loads the newest library that parses: `allNNN.vfp` sorted by NNN as a number, falling back to older ones.
    func load() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        let vfp = files.filter { $0.pathExtension.lowercased() == "vfp" }
            .sorted { (Self.version(of: $0), $0.lastPathComponent) > (Self.version(of: $1), $1.lastPathComponent) }
        for url in vfp {
            if let lib = try? AssistantLibrary(contentsOf: url) {
                library = lib
                fileName = url.lastPathComponent
                return
            }
        }
        library = nil
        fileName = nil
    }

    /// Copies a user-chosen library (`allNNN.vfp`, whatever its extension now) into Application Support once it
    /// parses. The installed copy is replaced atomically; importing the installed file itself changes nothing.
    func importLibrary(from url: URL) throws {
        _ = try AssistantLibrary(contentsOf: url)   // validate first: nothing is touched if it does not parse
        let fm = FileManager.default
        try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let name = url.pathExtension.lowercased() == "vfp" ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent + ".vfp"
        let dest = Self.folder.appendingPathComponent(name)
        if dest.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() {
            load()
            return
        }
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dest, create: true)
            .appendingPathComponent(name)
        try fm.copyItem(at: url, to: staging)
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: dest)
        }
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

    private weak var document: ConfigDocument?
    private var composer: AssistantComposer?
    private var lastImage: [UInt8] = []
    private var cancellables: Set<AnyCancellable> = []
    /// A wizard sheet is open on `composer`: reloads wait until it closes (its answers then no longer apply).
    private var wizardOpen = false
    private var reloadDeferred = false

    var memorySize: Int { document?.config.data.assistantMemory.count ?? AssistantComposer.memorySize }
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

    /// Battery preset index (`BatteryType_VEC`: 1-based in MetaGenerator.batteryPresets, 0 = none) the settings match.
    static func batteryType(of c: DeviceConfiguration) -> Int {
        guard let p = BatteryPresets.matching(c), let i = MetaGenerator.batteryPresets.firstIndex(of: p.id) else { return 0 }
        return i + 1
    }

    /// META for the configuration as it is now: settings edited since the file was opened are what the
    /// assistants must see.
    static func meta(for c: DeviceConfiguration) -> [UInt8] {
        MetaGenerator.source(for: c, batteryType: batteryType(of: c))
    }

    func reload() {
        guard let document else { return }
        if wizardOpen { reloadDeferred = true; return }
        let config = document.config
        lastImage = config.data.assistantMemory
        composer = nil
        installed = []
        codeSize = 0
        guard let lib = AssistantLibraryStore.shared.library else { status = .noLibrary; return }
        guard config.data.assistantMemory.count == AssistantComposer.memorySize else {
            status = .failed("\(AssistantError.badMemorySize(config.data.assistantMemory.count))")
            return
        }
        do {
            let c = try AssistantComposer(library: lib)
            c.languages = AssistantLibraryStore.languages
            c.meta = Self.meta(for: config)
            let r = try c.reconstruct(image: config.data.assistantMemory)
            guard r.success else {
                status = .failed(r.messages.first { $0.kind == .error || $0.kind == .fatal }?.text ?? L("The assistant program could not be read back."))
                return
            }
            if !c.items.isEmpty {
                let b = c.build()
                guard b.success else {
                    status = .failed(b.messages.first { $0.kind == .error || $0.kind == .fatal }.map(Self.clean) ?? L("The assistants could not be assembled."))
                    return
                }
                codeSize = b.code.count
                installed = describe(c, steps: b.steps)
            }
            composer = c
            status = .ready
        } catch {
            status = .failed("\(error)")
        }
    }

    /// Assistants available to add (framework excluded), with their menu titles.
    var available: [(package: AssistantPackage, title: String)] {
        guard let lib = AssistantLibraryStore.shared.library else { return [] }
        // Only what VE Configure lists in its Add menu: packages with a #MenuInfo (Hub-2 v2 and the framework have none).
        return lib.latest.filter { !["asfStart", "asfStop"].contains($0.baseName) && Self.hasMenuInfo($0) }
            .map { ($0, Self.title(of: $0)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func hasMenuInfo(_ p: AssistantPackage) -> Bool {
        p.scripts.values.contains { !(WizardText($0.bytes).lines("MenuInfo") ?? []).isEmpty }
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
            return content.options.indices.contains(v) ? lineText(content.options[v]) : "\(v)"
        case .check:
            let mask = Int64(p.values.first ?? 0)
            let on = content.options.indices.filter { $0 < 63 && mask >> $0 & 1 == 1 }.map { lineText(content.options[$0]) }
            return on.isEmpty ? L("None") : on.joined(separator: ", ")
        case .entry:
            return content.entry.map { pieces in
                pieces.map { piece -> String in
                    switch piece {
                    case .text(let runs): return runs.map(\.text).joined()
                    case .field(let i, let items):
                        guard i < p.values.count, i < p.step.fields.count else { return "?" }
                        let v = p.values[i]
                        if let items { let k = Int(Int64(v) - Int64(p.step.fields[i].min)); return items.indices.contains(k) ? items[k] : "\(v)" }
                        return p.step.fields[i].display(v)
                    }
                }.joined()
            }.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: Editing

    /// Starts the wizard of an installed assistant, or of a new one appended to the list. Nil when no sheet is
    /// needed: nothing to configure, or the wizard already ended (its result is then applied).
    func wizard(for index: Int?, adding package: AssistantPackage? = nil) -> WizardModel? {
        guard let c = composer, let document, !wizardOpen else { return nil }
        c.meta = Self.meta(for: document.config)
        let snapshot = (c.items, c.answers)
        if let package {
            guard !c.items.contains(where: { $0.name == package.baseName }) else {
                message = L("%@ is already installed. Use Configure to change it.", Self.title(of: package))
                return nil
            }
            c.items.append(.init(package: package))
        }
        let name: String
        if let package { name = package.baseName }
        else if let index, c.items.indices.contains(index) { name = c.items[index].name }
        else { return nil }
        let title = package.map(Self.title(of:)) ?? installed.first { $0.id == index }?.title ?? name
        wizardOpen = true
        let model = WizardModel(composer: c, assistant: name, title: title, languages: AssistantLibraryStore.languages,
                                expectedSteps: package == nil ? stepCounts[name] : nil) { [weak self] result in
            guard let self else { (c.items, c.answers) = snapshot; return }
            self.wizardOpen = false
            defer {
                if self.reloadDeferred { self.reloadDeferred = false; self.reload() }
            }
            guard let result else { (c.items, c.answers) = snapshot; return }
            // The answers belong to this composer and this configuration: if either changed meanwhile, drop them.
            guard !self.reloadDeferred, self.composer === c else {
                (c.items, c.answers) = snapshot
                self.message = L("The configuration changed while the assistant was open. Its answers were not applied.")
                return
            }
            self.program(c, actionName: package != nil ? L("Add %@", title) : L("Configure %@", title), wizardChanges: result.vecChanges) {
                (c.items, c.answers) = snapshot
            }
        }
        return model.finished ? nil : model
    }

    func remove(_ index: Int) {
        guard let c = composer, !wizardOpen, c.items.indices.contains(index) else { return }
        let snapshot = (c.items, c.answers)
        let name = installed.first { $0.id == index }?.title ?? c.items[index].name
        let item = c.items.remove(at: index)
        c.answers[item.name] = nil
        let left = managedSettingLabels(item.package)
        guard program(c, actionName: L("Remove %@", name), rollback: { (c.items, c.answers) = snapshot }) else { return }
        if !left.isEmpty {
            let before = message
            message = L("%@ was removed. The settings it managed keep the values it gave them: %@. Check them on their pages.",
                        name, left.joined(separator: ", ")) + (before.map { "\n\n" + $0 } ?? "")
        }
    }

    /// Removes every assistant (enabling the virtual switch requires it).
    func removeAll() {
        guard let c = composer, !wizardOpen, !c.items.isEmpty else { return }
        let snapshot = (c.items, c.answers)
        let left = c.items.flatMap { managedSettingLabels($0.package) }
        c.items.removeAll()
        c.answers = [:]
        guard program(c, actionName: L("Remove All Assistants"), rollback: { (c.items, c.answers) = snapshot }) else { return }
        if !left.isEmpty {
            message = L("The assistants were removed. The settings they managed keep the values they gave them: %@. Check them on their pages.",
                        Array(NSOrderedSet(array: left)).compactMap { $0 as? String }.joined(separator: ", "))
        }
    }

    func move(_ index: Int, by delta: Int) {
        guard let c = composer, !wizardOpen, c.items.indices.contains(index), c.items.indices.contains(index + delta) else { return }
        let snapshot = (c.items, c.answers)
        c.items.swapAt(index, index + delta)
        program(c, actionName: L("Reorder Assistants")) { (c.items, c.answers) = snapshot }
    }

    /// Names of the settings an assistant changes (its `_VEC` list) that this device has.
    private func managedSettingLabels(_ p: AssistantPackage) -> [String] {
        guard let config = document?.config else { return [] }
        let targets = MetaGenerator.vecTargets(config)
        return AssistantComposer.managedSettings(of: p).compactMap { name in
            switch targets[name] {
            case .setting(let id)?: return Catalog.shared.label(forSetting: id) ?? String(name.dropLast(4))
            case .flag(let n)?: return Catalog.shared.label(forFlag: n) ?? String(name.dropLast(4))
            case nil: return nil
            }
        }
    }

    /// Re-assembles everything and writes the program (the battery preset and settings the assistants chose, then
    /// the image) into the document. META is regenerated from the configuration as it is now.
    @discardableResult
    private func program(_ c: AssistantComposer, actionName: String, wizardChanges: [String: Value] = [:], rollback: () -> Void) -> Bool {
        guard let document else { rollback(); return false }
        c.meta = Self.meta(for: document.config)
        let r = c.build()
        guard r.success else {
            rollback()
            message = r.messages.first { $0.kind == .error || $0.kind == .fatal }.map(Self.clean) ?? L("The assistants could not be assembled.")
            return false
        }
        var preset: Notice?
        let applied: (DeviceConfiguration, batteryType: Int?)
        do {
            applied = try c.apply(r, to: document.config, extraChanges: wizardChanges) { index, cfg in
                guard MetaGenerator.batteryPresets.indices.contains(index - 1),
                      let p = Catalog.shared.batteryPresets.first(where: { $0.id == MetaGenerator.batteryPresets[index - 1] })
                else { return }
                preset = BatteryPresets.apply(p, to: &cfg)
            }
        } catch AssistantError.imageTooLarge(let needed, let size) {
            rollback()
            message = L("Not enough assistant memory: %@ bytes needed, %@ available.", "\(needed)", "\(size)")
            return false
        } catch {
            rollback()
            message = "\(error)"
            return false
        }
        let (new, battery) = applied
        lastImage = new.data.assistantMemory
        document.replace(with: new, actionName: actionName)
        codeSize = c.items.isEmpty ? 0 : r.code.count
        installed = describe(c, steps: r.steps)
        var notes: [String] = []
        if let preset {
            notes.append(L("The assistant selected a battery type.") + " " + preset.title + "\n" + preset.message)
        } else if let battery, battery > 0 {
            notes.append(L("The assistant selected battery preset %@. Check the Charger page.", "\(battery)"))
        }
        notes += r.messages.filter { $0.kind == .message }.map(Self.clean)
        if !notes.isEmpty && message == nil { message = notes.joined(separator: "\n\n") }
        return true
    }

    static func clean(_ m: AssemblerMessage) -> String {
        var t = m.text
        if t.hasPrefix("'") && t.hasSuffix("'") && t.count >= 2 { t = String(t.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        return t
    }
}
