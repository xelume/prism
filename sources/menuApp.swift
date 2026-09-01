import AppKit

@MainActor
private final class LoginWaitPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let message = NSTextField(wrappingLabelWithString:
        "请在浏览器中完成登录。不想继续时可以取消，当前账号不会改变。")
    private let cancelButton = NSButton(title: "取消登录", target: nil, action: nil)
    private var finishing = false
    var onCancel: (() -> Void)?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = "Prism"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let title = NSTextField(labelWithString: "正在等待浏览器登录")
        title.font = .boldSystemFont(ofSize: 17)
        title.alignment = .center
        message.alignment = .center
        message.maximumNumberOfLines = 3

        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [icon, title, message, progress, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(18, after: icon)
        stack.setCustomSpacing(20, after: progress)
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = panel.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -36),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: 6),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140)
        ])
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func finish() {
        finishing = true
        panel.orderOut(nil)
        panel.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if finishing { return true }
        cancel()
        return false
    }

    @objc private func cancel() {
        guard !finishing, cancelButton.isEnabled else { return }
        cancelButton.isEnabled = false
        cancelButton.title = "正在取消…"
        message.stringValue = "正在结束这次登录，当前账号和已保存的账号都不会改变。"
        onCancel?()
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class AccountRowView: NSStackView {
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
    }

    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.clear.cgColor }
}

@MainActor
private final class AccountManagerWindow: NSWindowController, NSWindowDelegate {
    private var accounts: [SavedAccount]
    private let currentIdentity: String?
    private let rows = NSStackView()
    private let listDocument = FlippedDocumentView()
    private let status = NSTextField(labelWithString: "")
    private var editingIdentity: String?
    private var working = false
    private let onRename: (String, String) async throws -> [SavedAccount]
    private let onDelete: (String) async throws -> [SavedAccount]
    private let onClose: () -> Void

    init(accounts: [SavedAccount], currentIdentity: String?,
         onRename: @escaping (String, String) async throws -> [SavedAccount],
         onDelete: @escaping (String) async throws -> [SavedAccount],
         onClose: @escaping () -> Void) {
        self.accounts = accounts
        self.currentIdentity = currentIdentity
        self.onRename = onRename
        self.onDelete = onDelete
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Prism"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 420)
        window.setFrameAutosaveName("PrismMainWindow")
        super.init(window: window)
        window.delegate = self

        let title = NSTextField(labelWithString: "账号管理")
        title.font = .boldSystemFont(ofSize: 24)
        let explanation = NSTextField(wrappingLabelWithString:
            "重命名只改变 Prism 中显示的名称。删除只移除本机钥匙串中的账号备份。")
        explanation.maximumNumberOfLines = 3
        explanation.alignment = .left
        explanation.textColor = .secondaryLabelColor

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
        scroll.layer?.cornerRadius = 10
        scroll.layer?.borderWidth = 0.5
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        listDocument.translatesAutoresizingMaskIntoConstraints = false
        listDocument.addSubview(rows)
        scroll.documentView = listDocument

        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.alignment = .left

        let stack = NSStackView(views: [title, explanation, scroll, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(20, after: explanation)
        stack.setCustomSpacing(12, after: scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 32),
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -40),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listDocument.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.topAnchor.constraint(equalTo: listDocument.topAnchor),
            rows.leadingAnchor.constraint(equalTo: listDocument.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: listDocument.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: listDocument.bottomAnchor)
        ])
        window.center()
        rebuildRows()
    }

    required init?(coder: NSCoder) { fatalError("Use init(accounts:currentIdentity:onRename:onDelete:onClose:)") }

    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose() }

    private func rebuildRows() {
        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if accounts.isEmpty {
            let empty = NSTextField(labelWithString: "没有已保存的账号")
            empty.textColor = .secondaryLabelColor
            empty.alignment = .left
            rows.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -32).isActive = true
            empty.heightAnchor.constraint(equalToConstant: 72).isActive = true
            return
        }
        for (index, account) in accounts.enumerated() {
            let row = AccountRowView(frame: .zero)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true

            let indicator = NSView()
            indicator.wantsLayer = true
            indicator.layer?.cornerRadius = 4
            indicator.layer?.backgroundColor = account.identity == currentIdentity
                ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
            indicator.widthAnchor.constraint(equalToConstant: 8).isActive = true
            indicator.heightAnchor.constraint(equalToConstant: 8).isActive = true
            indicator.setAccessibilityElement(false)
            row.addArrangedSubview(indicator)

            if editingIdentity == account.identity {
                let field = NSTextField(string: account.label)
                field.identifier = NSUserInterfaceItemIdentifier(account.identity)
                field.setAccessibilityLabel("新的账号名称")
                field.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
                let save = actionButton("保存", #selector(saveRename(_:)), identity: account.identity)
                let cancel = actionButton("取消", #selector(cancelRename(_:)), identity: account.identity)
                row.addArrangedSubview(field)
                row.addArrangedSubview(save)
                row.addArrangedSubview(cancel)
                DispatchQueue.main.async { field.selectText(nil) }
            } else {
                let label = NSTextField(labelWithString: account.label)
                label.font = .systemFont(ofSize: 15, weight: .medium)
                label.lineBreakMode = .byTruncatingMiddle
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                label.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
                label.setAccessibilityLabel(account.label +
                    (account.identity == currentIdentity ? "，当前账号" : ""))
                row.addArrangedSubview(label)
                let spacer = NSView()
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                row.addArrangedSubview(spacer)
                let rename = actionButton("重命名", #selector(beginRename(_:)), identity: account.identity)
                let delete = actionButton("删除", #selector(deleteAccount(_:)), identity: account.identity,
                                          destructive: true)
                row.addArrangedSubview(rename)
                row.addArrangedSubview(delete)
            }
            for view in row.arrangedSubviews { if let button = view as? NSButton { button.isEnabled = !working } }
            if index < accounts.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                rows.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -32).isActive = true
            }
        }
    }

    private func actionButton(_ title: String, _ action: Selector, identity: String,
                              destructive: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = destructive ? .systemRed : .controlAccentColor
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        button.identifier = NSUserInterfaceItemIdentifier(identity)
        button.setAccessibilityLabel((destructive ? "删除 " : "重命名 ") +
            (accounts.first(where: { $0.identity == identity })?.label ?? "账号"))
        return button
    }

    @objc private func beginRename(_ sender: NSButton) {
        guard !working, let identity = sender.identifier?.rawValue else { return }
        editingIdentity = identity
        status.stringValue = ""
        rebuildRows()
    }

    @objc private func cancelRename(_ sender: NSButton) {
        editingIdentity = nil
        status.stringValue = ""
        rebuildRows()
    }

    @objc private func saveRename(_ sender: NSButton) {
        guard !working, let identity = sender.identifier?.rawValue else { return }
        let fields = rows.arrangedSubviews.compactMap { $0 as? NSStackView }
            .flatMap { $0.arrangedSubviews }.compactMap { $0 as? NSTextField }
        guard let field = fields.first(where: { $0.identifier?.rawValue == identity }) else { return }
        let label = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 80,
              label.rangeOfCharacter(from: .controlCharacters) == nil else {
            status.stringValue = "账号名称应为 1–80 个字符，且不能包含控制字符。"
            NSSound.beep()
            return
        }
        runOperation(success: "账号已重命名") { try await self.onRename(identity, label) }
    }

    @objc private func deleteAccount(_ sender: NSButton) {
        guard !working, let identity = sender.identifier?.rawValue,
              let account = accounts.first(where: { $0.identity == identity }) else { return }
        let name = NSTextField(labelWithString: account.label)
        name.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        name.alignment = .center
        name.isSelectable = true
        name.setAccessibilityLabel("将删除备份的账号名称，可复制")
        name.widthAnchor.constraint(equalToConstant: 320).isActive = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除这个账号备份？"
        alert.informativeText = account.identity == currentIdentity
            ? "只会从 Prism 钥匙串中删除备份，不会退出当前登录。之后需要重新保存，才能从其他账号切回。"
            : "删除后不能再从 Prism 切换到这个账号，需要重新添加或登录。"
        alert.accessoryView = name
        alert.addButton(withTitle: "取消")
        let delete = alert.addButton(withTitle: "删除备份")
        delete.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        runOperation(success: "账号备份已删除") { try await self.onDelete(account.identity) }
    }

    private func runOperation(success: String,
                              operation: @escaping () async throws -> [SavedAccount]) {
        working = true
        status.stringValue = "正在保存…"
        rebuildRows()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                accounts = try await operation()
                editingIdentity = nil
                status.stringValue = success
            } catch {
                status.stringValue = (error as? SwitchError)?.message ?? "操作失败，请稍后再试。"
                NSSound.beep()
            }
            working = false
            rebuildRows()
        }
    }
}

@MainActor
final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem!
    private let runtime = MacRuntime()
    private let vault = KeychainVault()
    private var busy = false
    private let updates = AppUpdates()
    private var aboutWindow: AboutWindow?
    private var accountManager: AccountManagerWindow?
    private var updateItem: NSMenuItem?
    private var refreshTimer: Timer?
    private var loginTask: Task<Void, Never>?
    private var menuIsOpen = false
    private var accountItems: [String: [NSMenuItem]] = [:]
    private var accountStatusItem: NSMenuItem?
    private var authorizationItem: NSMenuItem?
    private var accountSeparator: NSMenuItem?
    private lazy var usage = UsageMonitor(load: { [weak self] in
        guard let self else { throw CancellationError() }
        let book = try await Task.detached { try KeychainVault().load(allowInteraction: false) }.value
        try Task.checkCancellation()
        return try UsageAccounts(book: book, current: self.runtime.currentAuth())
    }, fetch: { auth in try await UsageClient().fetch(auth) })

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try runtime.lock() }
        catch { show(error); NSApp.terminate(nil); return }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let icon = NSImage(named: "menuIcon") {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = true
            status.button?.image = icon
            status.button?.imagePosition = .imageLeading
        }
        status.button?.setAccessibilityLabel("Prism — ChatGPT / Codex 账号切换")
        updates.onChange = { [weak self] in
            self?.aboutWindow?.refresh()
            self?.rebuildMenu()
        }
        updates.start()
        usage.onChange = { [weak self] in self?.rebuildMenu() }
        rebuildMenu()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.usage.refresh()
                if self.menuIsOpen { self.updateUsageItems() }
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        usage.refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        menuIsOpen = true
        usage.refreshOnMenuOpen()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        // Let AppKit dispatch the selected item before rebuilding the menu structure.
        Task { @MainActor [weak self] in self?.rebuildMenu() }
    }

    private func rebuildMenu() {
        guard status != nil else { return }
        if menuIsOpen {
            // Update existing rows without replacing the tracked menu or reordering accounts.
            updateUsageItems()
            return
        }
        let menu = status.menu ?? NSMenu()
        menu.removeAllItems()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.minimumWidth = 340
        accountItems = [:]
        addItem("切换账号", to: menu)
        accountStatusItem = addItem("", to: menu)
        authorizationItem = addItem("授权并重试…", action: #selector(authorizeAccounts), to: menu)
        accountSeparator = .separator()
        menu.addItem(accountSeparator!)
        addItem("添加账号…", action: #selector(addAccount), to: menu)
        addItem("保存当前账号…", action: #selector(saveCurrent), to: menu)
        addItem("管理账号…", action: #selector(manageAccounts), to: menu)
        menu.addItem(.separator())
        addItem("关于 Prism…", action: #selector(about), to: menu)
        updateItem = addItem(updates.menuTitle, action: #selector(checkForUpdates), to: menu)
        updateItem?.isEnabled = updates.canCheck
        let quit = addItem("退出 Prism", action: #selector(exitTool), to: menu)
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
        status.menu = menu
        status.button?.title = busy ? "处理中…" : (status.button?.image == nil ? "账号" : "")
        status.button?.toolTip = nil
        updateUsageItems()
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector? = nil, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = action != nil && !busy && !updates.installationGate.installationRequested
        menu.addItem(item)
        return item
    }

    private func updateUsageItems() {
        guard let menu = status.menu, let accountSeparator else { return }
        let actionsAllowed = !busy && !updates.installationGate.installationRequested
        updateItem?.title = updates.menuTitle
        updateItem?.isHidden = updates.availableVersion == nil
        updateItem?.isEnabled = updates.canCheck

        let loadFailed = usage.loadError != nil
        accountStatusItem?.title = loadFailed ? "账号列表加载失败…"
            : usage.accounts.isEmpty ? (usage.refreshing ? "正在加载账号…" : "还没有保存账号")
            : "尚未登录 ChatGPT"
        accountStatusItem?.action = loadFailed ? #selector(accountLoadError) : nil
        accountStatusItem?.isEnabled = loadFailed && actionsAllowed
        accountStatusItem?.isHidden = !loadFailed && !usage.accounts.isEmpty && usage.currentIdentity != nil
        authorizationItem?.isHidden = !loadFailed
        authorizationItem?.isEnabled = actionsAllowed

        // Append newly loaded accounts; retain existing row identities until the menu closes.
        let orderedAccounts = usage.accounts.filter { $0.identity == usage.currentIdentity }
            + usage.accounts.filter { $0.identity != usage.currentIdentity }
        for account in orderedAccounts where accountItems[account.identity] == nil {
            let header = NSMenuItem(title: account.label, action: #selector(switchAccount(_:)), keyEquivalent: "")
            header.target = self
            header.representedObject = account.identity
            let rows = [header, NSMenuItem(title: "", action: nil, keyEquivalent: ""),
                        NSMenuItem(title: "", action: nil, keyEquivalent: "")]
            for row in rows.dropFirst() {
                row.indentationLevel = 1
                row.isEnabled = false
            }
            for row in rows { menu.insertItem(row, at: menu.index(of: accountSeparator)) }
            accountItems[account.identity] = rows
        }
        let identities = Set(usage.accounts.map(\.identity))
        for (identity, rows) in accountItems where !identities.contains(identity) {
            rows[0].attributedTitle = nil
            rows[0].title = loadFailed ? "暂时无法加载账号" : "这个账号已移除"
            rows[0].state = .off
            rows[0].isEnabled = false
            rows[0].setAccessibilityLabel(rows[0].title)
            for row in rows.dropFirst() {
                row.attributedTitle = nil
                row.title = "暂时无法查看额度"
            }
        }
        let now = Date()
        for account in usage.accounts {
            guard let rows = accountItems[account.identity] else { continue }
            let current = account.identity == usage.currentIdentity
            let state = usage.states[account.identity]
            var badges: [String] = current ? ["当前"] : []
            if let failure = state?.failure { badges.append(failureTitle(failure)) }
            let suffix = badges.isEmpty ? "" : "   " + badges.joined(separator: " · ")
            rows[0].title = account.label + suffix
            rows[0].state = current ? .on : .off
            let expired = state?.failure == .expired
            rows[0].action = expired && !current ? #selector(reauthenticateAccount(_:)) : #selector(switchAccount(_:))
            rows[0].isEnabled = actionsAllowed && !current && usage.savedIdentities.contains(account.identity)
            rows[0].attributedTitle = nil
            if current {
                rows[0].attributedTitle = NSAttributedString(string: rows[0].title,
                    attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            }
            let pending = state?.value != nil ? "暂无额度信息" : (state?.failure != nil ? "暂时无法查看额度" : (usage.refreshing ? "正在更新额度…" : "额度尚未更新"))
            let titles = [
                windowTitle("5 小时", state?.value?.fiveHour, failed: state?.failure != nil, pending: pending, now: now),
                windowTitle("每周", state?.value?.week, failed: state?.failure != nil, pending: pending, now: now)
            ]
            for (row, title) in zip(rows.dropFirst(), titles) {
                row.title = title
                row.attributedTitle = NSAttributedString(string: title,
                    attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
            }
            // Keep full labels available to VoiceOver without mouse-hover popups.
            rows[0].setAccessibilityLabel(account.label + (current ? "，当前账号" : "") + "，"
                + titles.joined(separator: "，") + (state?.failure.map { "，" + $0.message } ?? ""))
        }
    }

    private func failureTitle(_ failure: UsageFailure) -> String {
        switch failure {
        case .expired: return "需要重新登录"
        case .forbidden: return "无法查看额度"
        case .throttled: return "稍后再试"
        case .unavailable: return "更新失败"
        case .unsupported: return "暂无额度信息"
        }
    }

    private func windowTitle(_ label: String, _ window: UsageWindow?, failed: Bool,
                             pending: String, now: Date) -> String {
        guard let window else { return label + " · " + pending }
        let elapsed = window.resetsAt.map { $0 <= now.timeIntervalSince1970 } ?? false
        var text = "\(label) \(failed || elapsed ? "上次剩余" : "剩余") \(window.remainingPercent)%"
        guard let reset = window.resetsAt else { return text + " · 重置时间未知" }
        if label == "5 小时" {
            text += " · " + resetCountdown(reset, now: now)
        } else {
            let date = Date(timeIntervalSince1970: reset)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            let sameYear = formatter.calendar.component(.year, from: date) == formatter.calendar.component(.year, from: now)
            formatter.dateFormat = sameYear ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm"
            text += " · " + formatter.string(from: date) + " 重置"
            if elapsed { text += "（等待确认）" }
        }
        return text
    }

    private func resetCountdown(_ reset: TimeInterval, now: Date) -> String {
        let seconds = reset - now.timeIntervalSince1970
        guard seconds > 0 else { return "等待重置确认" }
        if seconds < 60 { return "不到1分钟后重置" }
        // Round to whole minutes; never imply that a passed boundary replenished quota.
        let minutes = Int(ceil(seconds / 60))
        if seconds < 3600 { return "\(minutes)分钟后重置" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return "\(hours)小时" + (remainder == 0 ? "" : "\(remainder)分钟") + "后重置"
    }

    @objc private func accountLoadError() {
        notify("账号列表加载失败", usage.loadError ?? "请关闭菜单后重新打开，再试一次。")
    }

    @objc private func authorizeAccounts() {
        guard !busy else { return }
        Task { @MainActor in
            do {
                _ = try await Task.detached { try KeychainVault().load() }.value
                usage.refresh(force: true)
            } catch { show(error) }
        }
    }

    @objc private func saveCurrent() {
        perform { [self] in
            let file = try runtime.authFile()
            var book = try vault.load()
            guard let current = try file.read() else { throw SwitchError("还没有可保存的账号。请先登录 ChatGPT 或 Codex，再试一次。") }
            book.remember(try AuthSnapshot(current))
            try vault.save(book)
            notify("账号已保存", "以后可以从 Prism 切换回这个账号。")
        }
    }

    @objc private func manageAccounts() {
        if let accountManager {
            accountManager.present()
            return
        }
        guard !busy, !usage.accounts.filter({ usage.savedIdentities.contains($0.identity) }).isEmpty else {
            notify("还没有可管理的账号", "请先保存或添加账号。")
            return
        }
        let saved = usage.accounts.filter { usage.savedIdentities.contains($0.identity) }
        let manager = AccountManagerWindow(accounts: saved, currentIdentity: usage.currentIdentity,
            onRename: { [weak self] identity, label in
                guard let self else { throw CancellationError() }
                return try await self.updateSavedAccounts { book in
                    try book.rename(identity: identity, to: label)
                }
            }, onDelete: { [weak self] identity in
                guard let self else { throw CancellationError() }
                return try await self.updateSavedAccounts { book in
                    try book.remove(identity: identity)
                }
            }, onClose: { [weak self] in self?.accountManager = nil })
        accountManager = manager
        manager.present()
    }

    private func updateSavedAccounts(_ mutation: (inout AccountBook) throws -> Void) async throws -> [SavedAccount] {
        guard !busy, updates.installationGate.beginAccountOperation() else {
            throw SwitchError("Prism 正在处理其他操作，请稍后再试。")
        }
        busy = true
        aboutWindow?.refresh()
        usage.pause()
        rebuildMenu()
        defer {
            busy = false
            updates.installationGate.endAccountOperation()
            usage.resume()
            aboutWindow?.refresh()
            rebuildMenu()
        }
        var book = try vault.load()
        try mutation(&book)
        try vault.save(book)
        return book.accounts
    }

    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard !busy, let target = sender.representedObject as? String,
              let account = usage.accounts.first(where: { $0.identity == target }),
              usage.savedIdentities.contains(target) else { return }
        let hasDesktopApp: Bool
        do { hasDesktopApp = try runtime.desktopApp() != nil }
        catch { show(error); return }
        let details = hasDesktopApp
            ? "切换时 ChatGPT 会重新打开。请先结束正在运行的 Codex 任务。"
            : "请先结束正在运行的 Codex 任务。"
        let alert = makeAlert("是否切换到「\(account.label)」？", details)
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: hasDesktopApp ? "切换并重开" : "切换账号")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        perform { [self] in try await change(to: target) }
    }

    @objc private func addAccount() {
        let alert = makeAlert("添加另一个账号", "将在浏览器中登录另一个 ChatGPT 账号。")
        alert.addButton(withTitle: "继续登录")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performLogin(expectedIdentity: nil)
    }

    @objc private func reauthenticateAccount(_ sender: NSMenuItem) {
        guard !busy, let target = sender.representedObject as? String,
              let account = usage.accounts.first(where: { $0.identity == target }),
              usage.states[target]?.failure == .expired else { return }
        let alert = makeAlert("重新登录「\(account.label)」？", "请在浏览器中登录同一个账号。")
        alert.addButton(withTitle: "继续登录")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performLogin(expectedIdentity: target)
    }

    private func performLogin(expectedIdentity: String?) {
        guard !busy, updates.installationGate.beginAccountOperation() else { return }
        busy = true
        aboutWindow?.refresh()
        usage.pause()
        rebuildMenu()
        let waiting = LoginWaitPanel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                waiting.finish()
                self.loginTask = nil
                self.busy = false
                self.updates.installationGate.endAccountOperation()
                self.usage.resume()
                self.aboutWindow?.refresh()
                self.rebuildMenu()
            }
            do { try await self.loginAccount(expectedIdentity: expectedIdentity) }
            catch is CancellationError { }
            catch { self.show(error) }
        }
        loginTask = task
        waiting.onCancel = { [weak self] in self?.loginTask?.cancel() }
        waiting.show()
    }

    private func loginAccount(expectedIdentity: String?) async throws {
        var book = try vault.load()
        let executable = try runtime.codexExecutable()
        let data = try await AccountLogin.run(executable: executable)
        let account = try AccountLogin.remember(data, expectedIdentity: expectedIdentity, in: &book)
        try vault.save(book)
        notify(expectedIdentity == nil ? "账号已添加" : "账号已重新登录", "「\(account.label)」现在可以切换了。")
    }

    private func change(to target: String) async throws {
        let file = try runtime.authFile(createDirectory: true)
        if let current = try file.read(), try AuthSnapshot(current).identity == target {
            notify("已经在使用这个账号", "无需再次切换。")
            return
        }
        var book = try vault.load()
        if !book.accounts.contains(where: { $0.identity == target }) {
            throw SwitchError("找不到这个账号，请重新添加。")
        }
        let hasDesktopApp = try runtime.desktopApp() != nil
        if hasDesktopApp { try await runtime.quitClient(confirmForce: confirmForceQuit) }
        else { try runtime.requireStopped() }
        try runtime.requireStopped()
        let change = try prepareChange(current: file.read(), target: target, book: &book, persist: vault.save)
        // Recheck immediately before the compare-and-replace. Other Codex clients do not
        // honor our lock, so this detects ordinary races but is not OS-wide isolation.
        try await applyChange(change, file: file, beforeWrite: { [self] in
            try runtime.requireStopped()
            try file.checkConfiguration()
        }, launch: { [self] in if hasDesktopApp { try await runtime.launch() } })
        notify("账号已切换", hasDesktopApp ? "ChatGPT 已重新打开。" : "切换完成。")
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, updates.installationGate.beginAccountOperation() else { return }
        busy = true
        aboutWindow?.refresh()
        usage.pause()
        rebuildMenu()
        Task { @MainActor in
            defer {
                busy = false
                updates.installationGate.endAccountOperation()
                usage.resume()
                aboutWindow?.refresh()
                rebuildMenu()
            }
            do { try await operation() }
            catch { show(error) }
        }
    }

    private func confirmForceQuit(_ processes: [ProcessEntry]) -> Bool {
        let list = processes.map { "• " + $0.summary }.joined(separator: "\n")
        let alert = makeAlert("ChatGPT 仍在运行，要强制结束吗？",
            "强制结束可能丢失未保存的内容或正在运行的任务。\n\n\(list)")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消切换")
        alert.addButton(withTitle: "强制结束并切换")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func makeAlert(_ title: String, _ message: String) -> NSAlert {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        return alert
    }

    private func notify(_ title: String, _ message: String) {
        let alert = makeAlert(title, message)
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private func show(_ error: Error) {
        let message = (error as? SwitchError)?.message ?? "请稍后再试。"
        notify("未能完成操作", message)
    }

    @objc private func about() {
        if aboutWindow == nil { aboutWindow = AboutWindow(updates: updates) }
        aboutWindow?.present()
    }

    @objc private func checkForUpdates() { updates.checkForUpdates(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Sparkle can request termination without the relaunch delegate (e.g.
        // installation on quit). Keep that path from interrupting an auth write too.
        busy ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        usage.pause()
    }

    @objc private func exitTool() { if !busy { NSApp.terminate(nil) } }
}
