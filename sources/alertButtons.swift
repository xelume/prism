import AppKit

enum AlertButtons {
    /// Adds a standard macOS confirmation pair with explicit keyboard roles.
    static func addConfirmation(to alert: NSAlert, cancelTitle: String,
                                confirmTitle: String) -> (cancel: NSButton, confirm: NSButton) {
        let cancel = alert.addButton(withTitle: cancelTitle)
        cancel.keyEquivalent = "\u{1b}"
        cancel.keyEquivalentModifierMask = []

        let confirm = alert.addButton(withTitle: confirmTitle)
        confirm.keyEquivalent = "\r"
        confirm.keyEquivalentModifierMask = []
        return (cancel, confirm)
    }
}
