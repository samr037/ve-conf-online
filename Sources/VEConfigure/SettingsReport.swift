import AppKit
import VEKit

/// VE Configure's "Export settings" / "Print settings": every visible setting, page by page, plus the assistants.
enum SettingsReport {
    struct Block { var title: String; var rows: [(String, String)] }

    static func blocks(for document: ConfigDocument) -> (header: [(String, String)], blocks: [Block]) {
        let c = document.config
        let ctx = document.ruleContext
        var header: [(String, String)] = [
            (L("Device"), c.modelName),
            (L("Serial"), c.serial ?? "—"),
            (L("Firmware"), c.firmware.description),
        ]
        if let d = c.readDate { header.append((L("Read"), d.formatted(date: .long, time: .shortened))) }
        if let u = document.url { header.append((L("File"), u.lastPathComponent)) }
        header.append((L("Exported"), Date().formatted(date: .long, time: .shortened)))

        var blocks: [Block] = []
        for section in Section.allCases where section != .assistants {
            for entry in SectionPages.entries(section, ctx) {
                for s in PageLayout.sections(entry.page) {
                    var rows: [(String, String)] = []
                    for row in s.rows where SectionPages.isVisible(row, ctx) {
                        let control = row.control
                        guard [.number, .toggle, .choice, .localToggle, .localChoice].contains(control.kind),
                              let codec = ValueCodec(control: control) else { continue }
                        let label = resolveText(control.label, ctx) ?? resolveText(control.caption, ctx) ?? control.changeListLabel ?? control.name
                        rows.append((label, codec.formatted(c, context: ctx)))
                    }
                    guard !rows.isEmpty else { continue }
                    let group = resolveText(s.title, ctx)
                    let pageTitle = section.title == entry.title ? section.title : "\(section.title) › \(entry.title)"
                    blocks.append(Block(title: group.map { "\(pageTitle) › \($0)" } ?? pageTitle, rows: rows))
                }
            }
        }
        for a in document.assistants.installed {
            blocks.append(Block(title: "\(Section.assistants.title) › \(a.title)", rows: a.summary.map { ($0.label, $0.value) }))
        }
        return (header, blocks)
    }

    static func plainText(for document: ConfigDocument) -> String {
        let (header, blocks) = blocks(for: document)
        var out = "VE Configure — \(L("VE.Bus configuration"))\n\n"
        for (k, v) in header { out += "\(k): \(v)\n" }
        for b in blocks {
            out += "\n\(b.title)\n" + String(repeating: "-", count: min(b.title.count, 72)) + "\n"
            let width = min(48, b.rows.map(\.0.count).max() ?? 0)
            for (k, v) in b.rows { out += k.padding(toLength: max(width, k.count), withPad: " ", startingAt: 0) + "  " + v + "\n" }
        }
        return out
    }

    static func attributed(for document: ConfigDocument) -> NSAttributedString {
        let (header, blocks) = blocks(for: document)
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 10)
        let value = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let tab = NSMutableParagraphStyle()
        tab.tabStops = [NSTextTab(textAlignment: .left, location: 260)]
        tab.headIndent = 260
        func line(_ s: String, _ attrs: [NSAttributedString.Key: Any]) { out.append(NSAttributedString(string: s, attributes: attrs)) }
        line("VE Configure\n", [.font: NSFont.systemFont(ofSize: 18, weight: .semibold)])
        for (k, v) in header {
            line("\(k)\t", [.font: body, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: tab])
            line("\(v)\n", [.font: value, .paragraphStyle: tab])
        }
        for b in blocks {
            let heading = NSMutableParagraphStyle()
            heading.paragraphSpacingBefore = 12
            line("\(b.title)\n", [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .paragraphStyle: heading,
                                    .foregroundColor: NSColor(Theme.victron)])
            for (k, v) in b.rows {
                line("\(k)\t", [.font: body, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: tab])
                line("\(v)\n", [.font: value, .paragraphStyle: tab])
            }
        }
        return out
    }

    static func print(_ document: ConfigDocument) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 40; info.rightMargin = 40
        info.isVerticallyCentered = false
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.textStorage?.setAttributedString(attributed(for: document))
        view.sizeToFit()
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = document.title
        op.run()
    }

    static func export(_ document: ConfigDocument) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = (document.url?.deletingPathExtension().lastPathComponent ?? "settings") + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try plainText(for: document).write(to: url, atomically: true, encoding: .utf8) } catch { NSAlert(error: error).runModal() }
    }
}
