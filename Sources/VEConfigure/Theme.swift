import AppKit
import SwiftUI

/// Visual world: the single-line diagrams of Victron manuals. Every colour has a job.
enum Theme {
    /// Victron blue: product blocks, selection, the lit path in the diagram.
    static let victron = dynamic(light: 0x1B5FAA, dark: 0x5B9BE6)
    /// The product block: in dark mode deeper than `victron` so its white symbols keep ≥ 4.5:1.
    static let victronBlock = dynamic(light: 0x1B5FAA, dark: 0x2B62A6)
    /// DC positive conductor.
    static let dcPositive = dynamic(light: 0xD7262E, dark: 0xF2575E)
    /// DC negative conductor.
    static let dcNegative = dynamic(light: 0x1D2126, dark: 0xC9CED6)
    /// AC line (brown) and neutral (blue).
    static let acLine = dynamic(light: 0x8A5A2B, dark: 0xC48A52)
    static let acNeutral = dynamic(light: 0x3A78C2, dark: 0x6FA3E0)
    /// Unlit conductors and symbols.
    static let wire = dynamic(light: 0xB9C0C9, dark: 0x4A525C)
    /// Drafting ground behind the diagram strip.
    static let drafting = dynamic(light: 0xF7F9FB, dark: 0x16191D)
    static let draftingGrid = dynamic(light: 0xE6EBF0, dark: 0x22272D)
    /// A value that differs from what was loaded.
    static let changed = victron
    /// Differs from the factory default (informative, not a warning).
    static let nonDefault = dynamic(light: 0x5B6570, dark: 0x9AA4AF)
    static let warning = dynamic(light: 0xB4531F, dark: 0xF0A35E)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

extension Font {
    /// Values are always set in tabular figures so a changing number never shifts its row.
    static let value = Font.system(.body).monospacedDigit()
    static let diagramLabel = Font.system(size: 10, weight: .medium)
}
