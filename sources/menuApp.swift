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

@MainActor
final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem!
    private let runtime = MacRuntime()
    private let vault = KeychainVault()
    private var busy = false
    private let updates = AppUpdates()
    private var aboutWindow: AboutWindow?
    private var updateItem: NSMenuItem?
    private var refreshTimer: Timer?
    private var loginTask: Task<Void, Never>?
    private var menuIsOpen = false
    private var accountItems: [String: [NSMenuItem]] = [:]
    private var accountStatusItem: NSMenuItem?
    private var authorizationItem: NSMenuItem?
    private var accountSeparator: NSMenuItem?
    private let statusBarUsagePreference = StatusBarUsagePreference()
    private lazy var usage = UsageMonitor(load: { [weak self] in
        guard let self else { throw CancellationError() }
        let book = try await Task.detached { try KeychainVault().load(allowInteraction: false) }.value
        try Task.checkCancellation()
        return try UsageAccounts(book: book, current: self.runtime.currentAuth())
    }, fetch: { auth in try await UsageClient().fetch(auth) }, statusBarUsageEnabled: { [weak self] in
        self?.statusBarUsagePreference.mode != .off
    })

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
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
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
        let savedAccounts = usage.accounts.filter { usage.savedIdentities.contains($0.identity) }
        let deleteAccountsItem = addItem("删除账号", to: menu)
        deleteAccountsItem.isEnabled = !savedAccounts.isEmpty && !busy
            && !updates.installationGate.installationRequested
        let deleteAccountsMenu = NSMenu()
        for account in savedAccounts {
            let item = NSMenuItem(title: account.label, action: #selector(deleteSavedAccount(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = account.identity
            item.attributedTitle = accountMenuTitle(account.label,
                workspace: account.isWorkspaceAccount, bold: false)
            item.isEnabled = !busy && !updates.installationGate.installationRequested
            item.setAccessibilityLabel("删除账号备份 " + account.label
                + (account.isWorkspaceAccount ? "，团队账号" : ""))
            deleteAccountsMenu.addItem(item)
        }
        deleteAccountsItem.submenu = deleteAccountsMenu
        let statusBarUsageItem = addItem("状态栏额度", to: menu)
        statusBarUsageItem.isEnabled = !busy && !updates.installationGate.installationRequested
        let statusBarUsageMenu = NSMenu()
        for mode in StatusBarUsageMode.allCases {
            let item = NSMenuItem(title: mode.menuTitle, action: #selector(setStatusBarUsageMode(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == statusBarUsagePreference.mode ? .on : .off
            item.isEnabled = !busy && !updates.installationGate.installationRequested
            statusBarUsageMenu.addItem(item)
        }
        statusBarUsageItem.submenu = statusBarUsageMenu
        menu.addItem(.separator())
        addItem("关于 Prism…", action: #selector(about), to: menu)
        updateItem = addItem(updates.menuTitle, action: #selector(checkForUpdates), to: menu)
        updateItem?.isEnabled = updates.canCheck
        let quit = addItem("退出 Prism", action: #selector(exitTool), to: menu)
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
        status.menu = menu
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

    private func accountMenuTitle(_ title: String, workspace: Bool, bold: Bool) -> NSAttributedString {
        let font = bold ? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
            : NSFont.menuFont(ofSize: NSFont.systemFontSize)
        let result = NSMutableAttributedString(string: title, attributes: [.font: font])
        guard workspace else { return result }
        result.append(NSAttributedString(string: "  团队", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))
        return result
    }

    private func updateUsageItems() {
        guard let menu = status.menu, let accountSeparator else { return }
        updateStatusBarTitle()
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
            var badges: [String] = []
            if let failure = state?.failure { badges.append(failureTitle(failure)) }
            let suffix = badges.isEmpty ? "" : "   " + badges.joined(separator: " · ")
            rows[0].title = account.label + suffix
            rows[0].state = current ? .on : .off
            let expired = state?.failure == .expired
            rows[0].action = expired && !current ? #selector(reauthenticateAccount(_:)) : #selector(switchAccount(_:))
            rows[0].isEnabled = actionsAllowed && !current && usage.savedIdentities.contains(account.identity)
            rows[0].attributedTitle = accountMenuTitle(rows[0].title,
                workspace: account.isWorkspaceAccount, bold: current)
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
            rows[0].setAccessibilityLabel(account.label
                + (account.isWorkspaceAccount ? "，团队账号" : "")
                + (current ? "，当前账号" : "") + "，"
                + titles.joined(separator: "，") + (state?.failure.map { "，" + $0.message } ?? ""))
        }
    }

    private func updateStatusBarTitle() {
        guard let button = status.button else { return }
        if busy {
            button.title = "处理中…"
            return
        }
        let currentUsage = usage.currentIdentity.flatMap { usage.states[$0]?.value }
        button.title = StatusBarUsageTitle.make(mode: statusBarUsagePreference.mode, usage: currentUsage)
            ?? (button.image == nil ? "账号" : "")
        let quota = StatusBarUsageTitle.make(mode: statusBarUsagePreference.mode, usage: currentUsage)
        button.setAccessibilityLabel(["Prism — ChatGPT / Codex 账号切换", quota]
            .compactMap { $0 }.joined(separator: "，"))
    }

    @objc private func setStatusBarUsageMode(_ sender: NSMenuItem) {
        guard !busy, let value = sender.representedObject as? String,
              let mode = StatusBarUsageMode(rawValue: value) else { return }
        statusBarUsagePreference.mode = mode
        usage.statusBarUsageModeDidChange()
        rebuildMenu()
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

    @objc private func deleteSavedAccount(_ sender: NSMenuItem) {
        guard !busy, let identity = sender.representedObject as? String,
              usage.savedIdentities.contains(identity),
              let account = usage.accounts.first(where: { $0.identity == identity }) else { return }
        let name = NSTextField(wrappingLabelWithString: account.label)
        name.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        name.alignment = .center
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byCharWrapping
        name.isSelectable = true
        name.setAccessibilityLabel("将删除备份的账号名称，可复制")
        name.translatesAutoresizingMaskIntoConstraints = false
        let nameContainer = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 44))
        nameContainer.addSubview(name)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: nameContainer.leadingAnchor),
            name.trailingAnchor.constraint(equalTo: nameContainer.trailingAnchor),
            name.centerYAnchor.constraint(equalTo: nameContainer.centerYAnchor)
        ])
        let alert = makeAlert("删除这个账号备份？", account.identity == usage.currentIdentity
            ? "只会删除 Prism 钥匙串中的备份，不会退出当前登录。之后切换账号时，Prism 仍会按安全流程保存离开账号的最新认证。"
            : "删除后不能再从 Prism 切换到这个账号，需要重新添加或登录。")
        alert.alertStyle = .warning
        alert.accessoryView = nameContainer
        alert.addButton(withTitle: "取消")
        let delete = alert.addButton(withTitle: "删除备份")
        delete.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        perform { [self] in
            var book = try vault.load()
            try book.remove(identity: identity)
            try vault.save(book)
        }
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
