import AppKit

@MainActor
final class AboutWindow: NSWindowController {
    private let updates: AppUpdates
    private let checkButton = NSButton(title: L10n.text("update.check"), target: nil, action: nil)
    private let automaticButton = NSButton(checkboxWithTitle: L10n.text("update.automaticDaily"), target: nil, action: nil)
    private let updateStatus = NSTextField(wrappingLabelWithString: "")

    init(updates: AppUpdates) {
        self.updates = updates
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 590),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("about.windowTitle")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let icon = NSImageView()
        icon.image = NSImage(named: "appIcon") ?? NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel(L10n.text("about.iconAccessibilityLabel"))
        icon.widthAnchor.constraint(equalToConstant: 80).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 80).isActive = true
        let title = NSTextField(labelWithString: "Prism")
        title.font = .boldSystemFont(ofSize: 22)
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? L10n.text("common.unknown")
        let build = info["CFBundleVersion"] as? String ?? L10n.text("common.unknown")
        let subtitle = NSTextField(labelWithString: L10n.text("about.version", version, build))
        subtitle.textColor = .secondaryLabelColor
        checkButton.target = self
        checkButton.action = #selector(check)
        checkButton.bezelStyle = .rounded
        automaticButton.target = self
        automaticButton.action = #selector(toggleAutomatic)
        updateStatus.font = .systemFont(ofSize: 12)
        updateStatus.textColor = .secondaryLabelColor
        updateStatus.alignment = .center
        updateStatus.widthAnchor.constraint(equalToConstant: 388).isActive = true
        let project = NSButton(title: L10n.text("about.projectHome"), target: self, action: #selector(openProject))
        project.bezelStyle = .rounded
        let safety = NSButton(title: L10n.text("about.securityAction"), target: self, action: #selector(showSafety))
        safety.bezelStyle = .rounded
        let links = NSStackView(views: [project, safety])
        links.spacing = 12
        let description = NSTextField(wrappingLabelWithString:
            L10n.text("about.description"))
        description.alignment = .center
        description.widthAnchor.constraint(equalToConstant: 388).isActive = true
        let disclaimer = NSTextField(labelWithString: L10n.text("about.disclaimer"))
        disclaimer.font = .systemFont(ofSize: 11)
        disclaimer.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, title, subtitle, description, checkButton,
                                        automaticButton, updateStatus, links, disclaimer])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -24)
        ])
        window.center()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("Use init(updates:)") }

    func present() {
        refresh()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        checkButton.isEnabled = updates.canCheck
        checkButton.title = updates.menuTitle
        automaticButton.isEnabled = updates.isConfigured
        automaticButton.state = updates.automaticallyChecks ? .on : .off
        if updates.installationGate.accountOperationInProgress {
            updateStatus.stringValue = L10n.text("update.waitForAccountOperation")
        } else if let message = updates.configurationMessage {
            updateStatus.stringValue = message
        } else if let version = updates.availableVersion {
            updateStatus.stringValue = L10n.text("update.available", version)
        } else {
            updateStatus.stringValue = L10n.text("update.passiveReminder")
        }
    }

    @objc private func check() { updates.checkForUpdates(checkButton) }
    @objc private func toggleAutomatic() { updates.setAutomaticallyChecks(automaticButton.state == .on) }
    @objc private func openProject() { Self.openProject() }
    static func openProject() {
        NSWorkspace.shared.open(URL(string: "https://github.com/xelume/prism")!)
    }

    @objc private func showSafety() {
        let alert = NSAlert()
        alert.messageText = L10n.text("about.securityTitle")
        alert.informativeText = L10n.text("about.securityMessage")
        alert.addButton(withTitle: L10n.text("common.ok"))
        if let window { alert.beginSheetModal(for: window) }
    }
}
