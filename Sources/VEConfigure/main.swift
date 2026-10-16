import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VEKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// `original` is the file as opened: saving over it needs an explicit confirmation.
    private var windows: [UUID: (window: NSWindow, document: ConfigDocument, state: WindowState, original: URL)] = [:]
    private var welcome: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        let args = CommandLine.arguments
        #if DEBUG
        // Design-review hooks; debug builds only (scripts/build-app.sh with VEC_CONFIG=debug for an installed app).
        if let i = args.firstIndex(of: "--capture"), i + 2 < args.count {
            Task { await captureWindows(file: URL(fileURLWithPath: args[i + 1]), dir: URL(fileURLWithPath: args[i + 2])) }
            return
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 2 < args.count {
            Task { await renderSnapshots(file: URL(fileURLWithPath: args[i + 1]), dir: URL(fileURLWithPath: args[i + 2])) }
            return
        }
        #endif
        // Skip options and their values (--language xx, -AppleLanguages (fr)).
        var files: [URL] = []
        var rest = args.dropFirst()[...]
        while let a = rest.popFirst() {
            if a.hasPrefix("-") { if a == "--language" || a.hasPrefix("-Apple") || a.hasPrefix("-NS") { _ = rest.popFirst() }; continue }
            files.append(URL(fileURLWithPath: a))
        }
        if files.isEmpty { showWelcome() } else { files.forEach(open) }
    }

    func application(_ application: NSApplication, open urls: [URL]) { urls.forEach(open) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome() }
        return true
    }

    // MARK: Windows

    func showWelcome() {
        if let welcome { welcome.makeKeyAndOrderFront(nil); return }
        let host = NSHostingView(rootView: WelcomeView(open: { [weak self] in self?.openDocument(nil) },
                                                       openRecent: { [weak self] in self?.open($0) }))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.title = "VE Configure"
        w.contentView = host
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        welcome = w
    }

    func open(_ url: URL) {
        let target = Self.canonical(url)
        if let existing = windows.values.first(where: { $0.document.url.map(Self.canonical) == target }) {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        do {
            let doc = try ConfigDocument(url: url)
            let state = WindowState()
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.contentView = NSHostingView(rootView: MainWindow(document: doc, state: state, save: { [weak self, weak doc] in
                if let doc { self?.save(doc) }
            }))
            w.title = doc.title
            w.representedURL = url
            // One autosave name per file: a shared name is refused for every window after the first.
            w.center()
            if !w.setFrameAutosaveName("ConfigWindow \(target.path)") {
                w.setFrameTopLeftPoint(NSPoint(x: w.frame.minX + 24, y: w.frame.maxY - 24))
            }
            w.delegate = self
            w.isReleasedWhenClosed = false
            w.toolbarStyle = .unified
            w.makeKeyAndOrderFront(nil)
            windows[doc.id] = (w, doc, state, url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            welcome?.close()
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Can't open “%@”", url.lastPathComponent)
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    private var keyDocument: ConfigDocument? {
        windows.values.first { $0.window.isKeyWindow }?.document
    }

    /// Resolves `.`/`..` and symlinks so one file opened through two paths is recognised.
    static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let entry = windows.values.first(where: { $0.window === sender }) else { return true }
        return confirmDiscard(entry.document)
    }

    /// ⌘Q: the same question as closing, for every edited window; Cancel (or a cancelled save) keeps the app running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for entry in windows.values where entry.document.isEdited {
            entry.window.makeKeyAndOrderFront(nil)
            if !confirmDiscard(entry.document) { return .terminateCancel }
        }
        return .terminateNow
    }

    /// Asks whether to save an edited document. Returns true when it may be closed (saved or discarded).
    private func confirmDiscard(_ document: ConfigDocument) -> Bool {
        guard document.isEdited else { return true }
        let alert = NSAlert()
        alert.messageText = L("Save the changes to “%@”?", document.title)
        alert.informativeText = L("%@ settings were changed. If you don't save, they're lost.", "\(document.changes.count)")
        alert.addButton(withTitle: L("Save…"))
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Don't Save"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(document)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if let key = windows.first(where: { $0.value.window === w })?.key { windows[key] = nil }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        windows.values.first { $0.window === window }?.document.undoManager
    }

    // MARK: Actions

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SettingFileType.all
        panel.allowsMultipleSelection = true
        panel.message = L("Choose a VE.Bus configuration downloaded from VRM (Remote VE Configure) or saved by VE Configure.")
        if panel.runModal() == .OK { panel.urls.forEach(open) }
    }

    @objc func saveDocument(_ sender: Any?) { if let d = keyDocument { save(d) } }

    /// Save stays enabled while blocked (so ⌘S explains why); disabled only when there is nothing to save.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(saveDocument(_:)): keyDocument.map { $0.canSave || $0.saveBlockReason != nil } ?? false
        case #selector(exportSettings(_:)), #selector(printSettings(_:)): keyDocument != nil
        default: true
        }
    }
    @objc func exportSettings(_ sender: Any?) { if let d = keyDocument { SettingsReport.export(d) } }
    @objc func printSettings(_ sender: Any?) { if let d = keyDocument { SettingsReport.print(d) } }

    @discardableResult
    func save(_ document: ConfigDocument) -> Bool {
        guard document.canSave else {
            if let reason = document.saveBlockReason {
                let alert = NSAlert()
                alert.messageText = L("This configuration can't be saved yet")
                alert.informativeText = reason
                alert.runModal()
            } else {
                NSSound.beep()
            }
            return false
        }
        let panel = NSSavePanel()
        panel.directoryURL = document.url?.deletingLastPathComponent()
        panel.allowedContentTypes = [SettingFileType.rvsc, SettingFileType.vsc].compactMap { $0 }
        let base = document.url?.deletingPathExtension().lastPathComponent ?? "configuration"
        panel.nameFieldStringValue = base.hasSuffix("-edited") ? base : base + "-edited"
        panel.message = L("Save a new file, then upload it through VRM. The original download stays untouched.")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        if let original = windows[document.id]?.original, Self.canonical(url) == Self.canonical(original) {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = L("Replace the original download “%@”?", original.lastPathComponent)
            alert.informativeText = L("This is the file you opened. Keep it as it is so you can go back to the inverter's current settings; save the edited configuration under a new name instead.")
            alert.addButton(withTitle: L("Cancel"))
            alert.addButton(withTitle: L("Replace Original"))
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
        }
        do {
            try document.save(to: url)
            windows[document.id]?.window.representedURL = url
            windows[document.id]?.window.title = document.title
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    @objc func undo(_ sender: Any?) { keyDocument?.undoManager.undo() }
    @objc func redo(_ sender: Any?) { keyDocument?.undoManager.redo() }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        submenu("VE Configure", [
            item(L("About VE Configure"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item(L("Hide VE Configure"), #selector(NSApplication.hide(_:)), "h"),
            item(L("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item(L("Quit VE Configure"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu(L("File"), [
            item(L("Open…"), #selector(openDocument(_:)), "o"),
            item(L("Save…"), #selector(saveDocument(_:)), "s"),
            .separator(),
            item(L("Export Settings…"), #selector(exportSettings(_:)), "e", [.command, .shift]),
            item(L("Print Settings…"), #selector(printSettings(_:)), "p"),
            .separator(),
            item(L("Close"), #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu(L("Edit"), [
            item(L("Undo"), Selector(("undo:")), "z"),
            item(L("Redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(L("Cut"), #selector(NSText.cut(_:)), "x"),
            item(L("Copy"), #selector(NSText.copy(_:)), "c"),
            item(L("Paste"), #selector(NSText.paste(_:)), "v"),
            item(L("Select All"), #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu(L("View"), [
            item(L("Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        submenu(L("Window"), [
            item(L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        return main
    }

    #if DEBUG
    // MARK: Snapshots (visual verification without screen-recording permission)

    /// Real on-screen captures (window key, toolbar and materials drawn) with `screencapture -l`, for design review.
    private func captureWindows(file: URL, dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        open(file)
        guard let entry = windows.values.first else { exit(1) }
        entry.document.setValue(2, 56.4, actionName: "")
        entry.document.setFlag(5, true, actionName: "")
        let w = entry.window
        w.setContentSize(NSSize(width: 1240, height: 800))
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        // Activation from a background launch is refused; ask System Events-style through osascript instead.
        let act = Process()
        act.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        act.arguments = ["-e", "tell application id \"local.veconfigure.mac\" to activate"]
        try? act.run()   // do not wait: the AppleEvent is answered by this very run loop
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            var shots: [(Section, String?, String)] = Section.allCases.map { ($0, nil, "\($0.rawValue)-\(dark ? "dark" : "light")") }
            for section in [Section.grid, .virtualSwitch] {
                for page in SectionPages.entries(section, entry.document.ruleContext) {
                    shots.append((section, page.id, "\(section.rawValue)-\(page.id)-\(dark ? "dark" : "light")"))
                }
            }
            for (section, page, name) in shots {
                entry.state.section = section
                if let page { entry.state.subpage[section] = page }
                w.makeKeyAndOrderFront(nil)
                try? await Task.sleep(nanoseconds: 900_000_000)
                let out = dir.appendingPathComponent("\(name).png").path
                for _ in 0..<3 where !FileManager.default.fileExists(atPath: out) {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    p.arguments = ["-o", "-x", "-l", String(w.windowNumber), out]
                    try? p.run()
                    p.waitUntilExit()
                    if !FileManager.default.fileExists(atPath: out) { try? await Task.sleep(nanoseconds: 500_000_000) }
                }
            }
        }
        exit(0)
    }

    private func renderSnapshots(file: URL, dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let doc = try? ConfigDocument(url: file) else { print("cannot open \(file.path)"); exit(1) }
        // Simulate two edits so the change list and "changed" markers are visible.
        doc.setValue(2, 56.4, actionName: "")
        doc.setFlag(5, true, actionName: "")
        for dark in [false, true] {
            for section in Section.allCases {
                let state = WindowState()
                state.section = section
                await Snapshot.render(MainWindow(document: doc, state: state, save: {}), size: NSSize(width: 1240, height: 800),
                                      dark: dark, to: dir.appendingPathComponent("\(section.rawValue)-\(dark ? "dark" : "light").png"))
                // Every sub-page (grid-code page, virtual-switch sheets), in a taller window to show whole forms.
                let entries = SectionPages.entries(section, doc.ruleContext)
                for entry in entries where entries.count > 1 || section != .assistants {
                    let sub = WindowState()
                    sub.section = section
                    sub.subpage[section] = entry.id
                    await Snapshot.render(MainWindow(document: doc, state: sub, save: {}), size: NSSize(width: 1240, height: 1400),
                                          dark: dark, to: dir.appendingPathComponent("\(section.rawValue)-\(entry.id)-\(dark ? "dark" : "light").png"))
                }
            }
            await Snapshot.render(WelcomeView(open: {}, openRecent: { _ in }), size: NSSize(width: 640, height: 420), dark: dark,
                                  to: dir.appendingPathComponent("welcome-\(dark ? "dark" : "light").png"))
            // The ESS wizard at its battery-system step (step 2), and an entry step (step 6).
            if let wizard = doc.assistants.wizard(for: 0) {
                wizard.next()
                await Snapshot.render(WizardView(model: wizard), size: NSSize(width: 600, height: 500), dark: dark,
                                      to: dir.appendingPathComponent("wizard-radio-\(dark ? "dark" : "light").png"))
                for _ in 0..<4 { wizard.next() }
                await Snapshot.render(WizardView(model: wizard), size: NSSize(width: 600, height: 500), dark: dark,
                                      to: dir.appendingPathComponent("wizard-entry-\(dark ? "dark" : "light").png"))
                wizard.cancel()
            }
        }
        if CommandLine.arguments.contains("--export") { print(SettingsReport.plainText(for: doc)) }
        exit(0)
    }
    #endif
}

enum SettingFileType {
    static let rvsc = UTType(filenameExtension: "rvsc", conformingTo: .data)
    static let vsc = UTType(filenameExtension: "vsc", conformingTo: .data)
    static var all: [UTType] { [rvsc, vsc].compactMap { $0 } }
}

#if DEBUG
@MainActor
enum Snapshot {
    static func render<V: View>(_ view: V, size: NSSize, dark: Bool, to url: URL) async {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
#endif

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
