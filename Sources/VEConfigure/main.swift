import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VEKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var windows: [UUID: (window: NSWindow, document: ConfigDocument, state: WindowState)] = [:]
    private var welcome: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 2 < args.count {
            Task { await renderSnapshots(file: URL(fileURLWithPath: args[i + 1]), dir: URL(fileURLWithPath: args[i + 2])) }
            return
        }
        let files = args.dropFirst().filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }
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
        if let existing = windows.values.first(where: { $0.document.url == url }) {
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
            w.setFrameAutosaveName("ConfigWindow")
            w.delegate = self
            w.isReleasedWhenClosed = false
            w.toolbarStyle = .unified
            w.makeKeyAndOrderFront(nil)
            windows[doc.id] = (w, doc, state)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            welcome?.close()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Can't open “\(url.lastPathComponent)”"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    private var keyDocument: ConfigDocument? {
        windows.values.first { $0.window.isKeyWindow }?.document
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let entry = windows.values.first(where: { $0.window === sender }), entry.document.isEdited else { return true }
        let alert = NSAlert()
        alert.messageText = "Save the changes to “\(entry.document.title)”?"
        alert.informativeText = "\(entry.document.changes.count) settings were changed. If you don't save, they're lost."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(entry.document)
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
        panel.message = "Choose a VE.Bus configuration downloaded from VRM (Remote VE Configure) or saved by VE Configure."
        if panel.runModal() == .OK { panel.urls.forEach(open) }
    }

    @objc func saveDocument(_ sender: Any?) { if let d = keyDocument { save(d) } }

    @discardableResult
    func save(_ document: ConfigDocument) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [SettingFileType.rvsc, SettingFileType.vsc].compactMap { $0 }
        let base = document.url?.deletingPathExtension().lastPathComponent ?? "configuration"
        panel.nameFieldStringValue = base.hasSuffix("-edited") ? base : base + "-edited"
        panel.message = "Save a new file, then upload it through VRM. The original download stays untouched."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
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
            item("About VE Configure", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide VE Configure", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit VE Configure", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("File", [
            item("Open…", #selector(openDocument(_:)), "o"),
            item("Save…", #selector(saveDocument(_:)), "s"),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("View", [
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        return main
    }

    // MARK: Snapshots (visual verification without screen-recording permission)

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
        exit(0)
    }
}

enum SettingFileType {
    static let rvsc = UTType(filenameExtension: "rvsc", conformingTo: .data)
    static let vsc = UTType(filenameExtension: "vsc", conformingTo: .data)
    static var all: [UTType] { [rvsc, vsc].compactMap { $0 } }
}

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

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
