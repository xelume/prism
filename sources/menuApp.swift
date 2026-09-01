import AppKit

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
        addItem("保存当前账号", action: #selector(saveCurrent), to: menu)
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
        accountStatusItem?.title = loadFailed ? "无法读取账号…"
            : usage.accounts.isEmpty ? (usage.refreshing ? "正在读取账号…" : "暂无已保存账号")
            : "当前未登录"
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
            rows[0].title = loadFailed ? "账号暂不可用" : "账号已移除"
            rows[0].state = .off
            rows[0].isEnabled = false
            rows[0].setAccessibilityLabel(rows[0].title)
            for row in rows.dropFirst() {
                row.attributedTitle = nil
                row.title = "额度暂不可用"
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
            let pending = state?.value != nil ? "暂无额度数据" : (state?.failure != nil ? "额度暂不可用" : (usage.refreshing ? "正在查询额度…" : "尚未获取额度"))
            let titles = [
                windowTitle("5h", state?.value?.fiveHour, failed: state?.failure != nil, pending: pending, now: now),
                windowTitle("Week", state?.value?.week, failed: state?.failure != nil, pending: pending, now: now)
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
        case .expired: return "登录失效"
        case .forbidden: return "访问受限"
        case .throttled: return "稍后重试"
        case .unavailable: return "查询失败"
        case .unsupported: return "暂不支持"
        }
    }

    private func windowTitle(_ label: String, _ window: UsageWindow?, failed: Bool,
                             pending: String, now: Date) -> String {
        guard let window else { return label + " · " + pending }
        let elapsed = window.resetsAt.map { $0 <= now.timeIntervalSince1970 } ?? false
        var text = "\(label) \(failed || elapsed ? "上次剩余" : "剩余") \(window.remainingPercent)%"
        guard let reset = window.resetsAt else { return text + " · 重置时间未知" }
        if label == "5h" {
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
        notify("无法读取账号", usage.loadError ?? "请重新展开菜单重试。")
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
            guard let current = try file.read() else { throw SwitchError("当前没有文件登录状态。请先在官方客户端登录。") }
            book.remember(try AuthSnapshot(current))
            try vault.save(book)
            notify("账号已保存", "认证备份已更新到本机钥匙串。")
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
            ? "将退出 ChatGPT，并自动备份当前账号的最新认证，再重开客户端。请先结束终端／IDE 中的 Codex 任务；这些客户端也会共用切换后的账号。设置与任务文件不变。"
            : "将自动备份当前账号的最新认证，再替换默认认证。请先结束终端／IDE 中的 Codex 任务；Prism 不会强制结束它们，也不会启动新进程。设置与任务文件不变。"
        let alert = makeAlert("是否切换到「\(account.label)」？", details)
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: hasDesktopApp ? "切换并重开" : "切换账号")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        perform { [self] in try await change(to: target) }
    }

    @objc private func addAccount() {
        let alert = makeAlert("添加另一个账号", "将在浏览器中通过官方 Codex 登录另一个 ChatGPT 账号。当前 ChatGPT、Codex 和 IDE 任务不会退出，当前登录不会改变。登录结果只在隔离目录中暂存，校验后保存到本机钥匙串。")
        alert.addButton(withTitle: "打开登录页")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { [self] in try await loginAccount(expectedIdentity: nil) }
    }

    @objc private func reauthenticateAccount(_ sender: NSMenuItem) {
        guard !busy, let target = sender.representedObject as? String,
              let account = usage.accounts.first(where: { $0.identity == target }),
              usage.states[target]?.failure == .expired else { return }
        let alert = makeAlert("重新登录「\(account.label)」？", "将在浏览器中通过官方 Codex 重新认证此账号。当前 ChatGPT、Codex 和 IDE 任务不会退出，当前登录不会改变。必须登录同一个账号，否则不会更新备份。")
        alert.addButton(withTitle: "打开登录页")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { [self] in try await loginAccount(expectedIdentity: target) }
    }

    private func loginAccount(expectedIdentity: String?) async throws {
        var book = try vault.load()
        let executable = try runtime.codexExecutable()
        let data = try await AccountLogin.run(executable: executable)
        let account = try AccountLogin.remember(data, expectedIdentity: expectedIdentity, in: &book)
        try vault.save(book)
        notify(expectedIdentity == nil ? "账号已添加" : "账号已重新登录",
               "「\(account.label)」已保存到本机钥匙串。当前登录未改变。")
    }

    private func change(to target: String) async throws {
        let file = try runtime.authFile(createDirectory: true)
        if let current = try file.read(), try AuthSnapshot(current).identity == target {
            notify("已是当前账号", "无需重复退出和重开客户端。")
            return
        }
        var book = try vault.load()
        if !book.accounts.contains(where: { $0.identity == target }) {
            throw SwitchError("目标备份不存在，未退出客户端。")
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
        notify(hasDesktopApp ? "已替换认证并重开客户端" : "已替换认证",
               hasDesktopApp ? "请在 ChatGPT 头像菜单核对账号。" : "之后启动的 Codex CLI 或 IDE 任务将使用此账号。")
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
        let alert = makeAlert("强制结束仍未退出的客户端进程？",
            "以下进程仍未退出，已确认属于本次客户端进程树。强制结束可能导致未保存内容或正在运行的任务丢失。\n\n\(list)\n\n只会结束清单中身份仍匹配的进程，不会强制结束独立终端／IDE 的 Codex。取消不会切换账号。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消切换")
        alert.addButton(withTitle: "强制结束并继续")
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
        let message = (error as? SwitchError)?.message ?? "操作失败。未输出认证内容；请检查文件权限或钥匙串访问权限。"
        notify("操作未完成", message)
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
