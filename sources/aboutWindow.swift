import AppKit

@MainActor
final class AboutWindow: NSWindowController {
    private let updates: AppUpdates
    private let checkButton = NSButton(title: "检查更新…", target: nil, action: nil)
    private let automaticButton = NSButton(checkboxWithTitle: "每天自动检查更新", target: nil, action: nil)
    private let updateStatus = NSTextField(wrappingLabelWithString: "")

    init(updates: AppUpdates) {
        self.updates = updates
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 590),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "关于 Prism"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let icon = NSImageView()
        icon.image = NSImage(named: "appIcon") ?? NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel("Prism 图标")
        icon.widthAnchor.constraint(equalToConstant: 80).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 80).isActive = true
        let title = NSTextField(labelWithString: "Prism")
        title.font = .boldSystemFont(ofSize: 22)
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "未知"
        let build = info["CFBundleVersion"] as? String ?? "未知"
        let subtitle = NSTextField(labelWithString: "版本 \(version)（\(build)） · xelume 星烁")
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
        let project = NSButton(title: "项目主页", target: self, action: #selector(openProject))
        project.bezelStyle = .rounded
        let safety = NSButton(title: "账号安全说明…", target: self, action: #selector(showSafety))
        safety.bezelStyle = .rounded
        let links = NSStackView(views: [project, safety])
        links.spacing = 12
        let description = NSTextField(wrappingLabelWithString:
            "快速保存和切换 ChatGPT / Codex 账号。")
        description.alignment = .center
        description.widthAnchor.constraint(equalToConstant: 388).isActive = true
        let disclaimer = NSTextField(labelWithString: "独立工具，未经 OpenAI 官方支持。")
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
            updateStatus.stringValue = "账号操作完成后即可安装更新。"
        } else if let message = updates.configurationMessage {
            updateStatus.stringValue = message
        } else if let version = updates.availableVersion {
            updateStatus.stringValue = "新版本 \(version) 可用，点击查看更新说明。"
        } else {
            updateStatus.stringValue = "发现新版本时提醒我，不会自动下载或安装。"
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
        alert.messageText = "账号安全说明"
        alert.informativeText = "账号信息保存在本机钥匙串中，不会同步到 iCloud。Prism 不会读取你的密码。\n\n切换账号不会删除本地设置和任务，但云端内容、订阅及权限取决于当前账号。\n\n本工具未经 OpenAI 官方支持。"
        alert.addButton(withTitle: "知道了")
        if let window { alert.beginSheetModal(for: window) }
    }
}
