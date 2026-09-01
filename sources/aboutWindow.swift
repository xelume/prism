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
        let safety = NSButton(title: "安全与兼容说明…", target: self, action: #selector(showSafety))
        safety.bezelStyle = .rounded
        let links = NSStackView(views: [project, safety])
        links.spacing = 12
        let description = NSTextField(wrappingLabelWithString:
            "管理本机 ChatGPT / Codex 账号，保留设置、插件和任务文件。账号备份仅保存在本机钥匙串。\n\n更新仅替换并重启 Prism，不会退出官方客户端或更改登录。")
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
            updateStatus.stringValue = "正在处理账号，更新安装将等待操作完成。"
        } else if let message = updates.configurationMessage {
            updateStatus.stringValue = message
        } else if let version = updates.availableVersion {
            updateStatus.stringValue = "新版本 \(version) 可用，点击查看更新说明。"
        } else {
            updateStatus.stringValue = "自动检查只提醒，不会自动下载或安装。"
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
        alert.messageText = "安全与兼容说明"
        alert.informativeText = "仅更换默认 ~/.codex/auth.json 或 Codex Direct Keyring 认证，保留设置、插件和任务文件。账号备份存入本机钥匙串，不同步到 iCloud。\n\n仅支持已检查版本 26.825.51511 的文件认证和 Direct Keyring；Secrets 等未知后端会安全停止。会清理已确认属于客户端的残留进程；强制结束前需确认，独立终端／IDE 进程不会自动结束。不会读取密码、修改官方应用或自动登录。后台定期使用各账号已有认证向官方服务查询额度，不自动续期或改写登录。切换期间请勿另行启动 Codex。\n\n本地任务文件不按账号隔离，切换账号不会隔离数据；云端会话、订阅、权限和插件授权由当前账号决定。本工具未经 OpenAI 官方支持。"
        alert.addButton(withTitle: "知道了")
        if let window { alert.beginSheetModal(for: window) }
    }
}
