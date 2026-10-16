import AppKit
import VEKit

/// VE Configure's safety confirmations, with its own wording (strings at 0x55e988, 0x5607ac, 0x55da34).
enum Confirmations {
    static func ask(_ message: String, informative: String, continueTitle: String) -> Bool {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = message
        a.informativeText = informative
        a.addButton(withTitle: continueTitle)
        a.addButton(withTitle: L("Cancel"))
        return a.runModal() == .alertFirstButtonReturn
    }

    /// LOM type set to "disabled" (raw & 3 == 2) outside Denmark (18/19, where it is required).
    static func allowLOM(control: String, newRaw: Int, config: DeviceConfiguration) -> Bool {
        guard control == "LOMAC0SettingComboBox" || control == "LOMAC1SettingComboBox", newRaw & 3 == 2 else { return true }
        let code = Int(config.raw(81))
        guard code != 18 && code != 19 else { return true }
        return ask(L("Safety warning!"),
                   informative: L("Disabling the LOM detection mechanism can result in dangerous AC voltages to be present on the AC input terminals of the Multi for an extended period of time when the AC input is 'unplugged'. It might be advisable to install anti-islanding protection equipment in the AC input line of the Multi/Quattro system to make sure that the system is disconnected from the grid in case of a mains failure! Disabling the LOM detection can be useful in installations where a generator (or other weak AC source) is connected to the AC input, because some generators become unstable when LOM detection is enabled. Disabling the LOM detection for an AC input will cause the device not to be compliant to the selected grid code on that AC input!")
                       + "\n\n" + L("Do you want to continue and disable the LOM detection?"),
                   continueTitle: L("Disable LOM Detection"))
    }

    static func allowMicrogrid() -> Bool {
        ask(L("Safety warning!"),
            informative: L("Enabling microgrid operation will result in dangerous AC voltages to be present on the AC input terminals of the Multi! Use this option with care!"),
            continueTitle: L("Enable Microgrid"))
    }

    /// Enabling the virtual switch removes every assistant (VE Configure 0x55da34).
    static func allowVirtualSwitch(assistantCount: Int) -> Bool {
        guard assistantCount > 0 else { return true }
        return ask(L("Warning"),
                   informative: L("Enabling the virtual switch will disable the assistant functionality. All configured assistants will be removed! Continue?"),
                   continueTitle: L("Remove Assistants"))
    }

    /// Runs the grid-code selection dialogs; returns the code to apply, or nil to keep the current one.
    static func resolve(_ choice: GridPages.Choice) -> Int? {
        switch choice {
        case .accept(let n):
            return n
        case .reject(let message):
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = L("Grid code not changed")
            a.informativeText = message
            a.addButton(withTitle: L("OK"))
            a.runModal()
            return nil
        case .propose(let message, let alternative, let button, let keep):
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = L("Grid code")
            a.informativeText = message
            a.addButton(withTitle: button)
            if let keep { a.addButton(withTitle: L("Keep Option %d", keep)) }
            a.addButton(withTitle: L("Cancel"))
            switch a.runModal() {
            case .alertFirstButtonReturn: return alternative
            case .alertSecondButtonReturn: return keep
            default: return nil
            }
        case .confirm(let message, let button, let then):
            guard ask(L("Grid code"), informative: message, continueTitle: button) else { return nil }
            return resolve(then)
        }
    }
}
