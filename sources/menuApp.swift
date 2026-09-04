import AppKit

private enum StatusBarUsageImage {
    private static let height: CGFloat = 18
    private static let iconWidth: CGFloat = 18
    private static let spacing: CGFloat = 3

    static func make(icon: NSImage?, title: String) -> NSImage? {
        guard title.split(separator: "\n").count == 2 else { return nil }
        let font = NSFont.systemFont(ofSize: 9, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 9
        paragraph.maximumLineHeight = 9
        let text = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ])
        let textSize = text.boundingRect(with: NSSize(width: .greatestFiniteMagnitude, height: height),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).integral.size
        let textX = icon == nil ? 0 : iconWidth + spacing
        let image = NSImage(size: NSSize(width: textX + textSize.width, height: height), flipped: true) { _ in
            if let icon {
                icon.draw(in: NSRect(x: 0, y: 0, width: iconWidth, height: height), from: .zero,
                    operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            text.draw(with: NSRect(x: textX, y: (height - textSize.height) / 2,
                                   width: textSize.width, height: textSize.height),
                      options: [.usesLineFragmentOrigin, .usesFontLeading])
            return true
        }
        image.isTemplate = true
        return image
    }
}

@MainActor
private final class LoginWaitPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let message = NSTextField(wrappingLabelWithString:
        L10n.text("login.wait.message"))
    private let cancelButton = NSButton(title: L10n.text("login.cancel"), target: nil, action: nil)
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

        let title = NSTextField(labelWithString: L10n.text("login.wait.title"))
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
        cancelButton.title = L10n.text("login.canceling")
        message.stringValue = L10n.text("login.canceling.message")
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
    private var statusIcon: NSImage?
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
            statusIcon = icon
            status.button?.image = icon
            status.button?.imagePosition = .imageLeading
        }
        status.button?.setAccessibilityLabel(L10n.text("accessibility.statusItem"))
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
        menu.minimumWidth = 280
        accountItems = [:]
        addItem(L10n.text("menu.account.switch"), to: menu)
        accountStatusItem = addItem("", to: menu)
        authorizationItem = addItem(L10n.text("menu.account.authorizeRetry"), action: #selector(authorizeAccounts), to: menu)
        accountSeparator = .separator()
        menu.addItem(accountSeparator!)
        addItem(L10n.text("menu.account.add"), action: #selector(addAccount), to: menu)
        let savedAccounts = usage.accounts.filter { usage.savedIdentities.contains($0.identity) }
        let deleteAccountsItem = addItem(L10n.text("menu.account.delete"), to: menu)
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
            item.setAccessibilityLabel(L10n.text("accessibility.account.deleteBackup", account.label)
                + (account.isWorkspaceAccount ? L10n.text("accessibility.account.workspaceSuffix") : ""))
            deleteAccountsMenu.addItem(item)
        }
        deleteAccountsItem.submenu = deleteAccountsMenu
        let statusBarUsageItem = addItem(L10n.text("menu.statusBarUsage"), to: menu)
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
        addItem(L10n.text("menu.about"), action: #selector(about), to: menu)
        updateItem = addItem(updates.menuTitle, action: #selector(checkForUpdates), to: menu)
        updateItem?.isEnabled = updates.canCheck
        let quit = addItem(L10n.text("menu.quit"), action: #selector(exitTool), to: menu)
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
        result.append(NSAttributedString(string: "  team", attributes: [
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
        accountStatusItem?.title = loadFailed ? L10n.text("menu.account.loadFailed")
            : usage.accounts.isEmpty ? (usage.refreshing ? L10n.text("menu.account.loading") : L10n.text("menu.account.noneSaved"))
            : L10n.text("menu.account.notSignedIn")
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
            let rows = [header] + UsageWindowKind.allCases.map { _ in
                NSMenuItem(title: "", action: nil, keyEquivalent: "")
            }
            for row in rows.dropFirst() {
                row.indentationLevel = 1
                row.isEnabled = false
                row.isHidden = true
            }
            for row in rows { menu.insertItem(row, at: menu.index(of: accountSeparator)) }
            accountItems[account.identity] = rows
        }
        let identities = Set(usage.accounts.map(\.identity))
        for (identity, rows) in accountItems where !identities.contains(identity) {
            rows[0].attributedTitle = nil
            rows[0].title = loadFailed ? L10n.text("menu.account.temporarilyUnavailable") : L10n.text("menu.account.removed")
            rows[0].state = .off
            rows[0].isEnabled = false
            rows[0].setAccessibilityLabel(rows[0].title)
            for row in rows.dropFirst() {
                row.attributedTitle = nil
                row.title = ""
                row.isHidden = true
            }
        }
        let now = Date()
        for account in usage.accounts {
            guard let rows = accountItems[account.identity] else { continue }
            let current = account.identity == usage.currentIdentity
            let state = usage.states[account.identity]
            var badges: [String] = []
            if let failure = state?.failure, let title = failureTitle(failure) { badges.append(title) }
            let suffix = badges.isEmpty ? "" : "   " + badges.joined(separator: " · ")
            rows[0].title = account.label + suffix
            rows[0].state = current ? .on : .off
            let expired = state?.failure == .expired
            rows[0].action = expired && !current ? #selector(reauthenticateAccount(_:)) : #selector(switchAccount(_:))
            rows[0].isEnabled = actionsAllowed && !current && usage.savedIdentities.contains(account.identity)
            rows[0].attributedTitle = accountMenuTitle(rows[0].title,
                workspace: account.isWorkspaceAccount, bold: current)
            var titles: [String] = []
            for (row, kind) in zip(rows.dropFirst(), UsageWindowKind.allCases) {
                guard let window = kind.window(in: state?.value) else {
                    row.attributedTitle = nil
                    row.title = ""
                    row.isHidden = true
                    continue
                }
                let title = UsageMenuTitle.make(kind: kind, window: window, now: now)
                titles.append(title)
                row.title = title
                row.attributedTitle = NSAttributedString(string: title,
                    attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
                row.isHidden = false
            }
            // Keep full labels available to VoiceOver without mouse-hover popups.
            rows[0].setAccessibilityLabel(account.label
                + (account.isWorkspaceAccount ? L10n.text("accessibility.account.workspaceSuffix") : "")
                + (current ? L10n.text("accessibility.account.currentSuffix") : "") + L10n.text("accessibility.separator")
                + titles.joined(separator: "，") + (state?.failure.map { "，" + $0.message } ?? ""))
        }
    }

    private func updateStatusBarTitle() {
        guard let button = status.button else { return }
        if busy {
            button.image = statusIcon
            button.imagePosition = .imageLeading
            button.title = L10n.text("status.processing")
            button.font = .menuBarFont(ofSize: 0)
            return
        }
        let currentUsage = usage.currentIdentity.flatMap { usage.states[$0]?.value }
        let quota = StatusBarUsageTitle.make(mode: statusBarUsagePreference.mode, usage: currentUsage)
        if let quota, let image = StatusBarUsageImage.make(icon: statusIcon, title: quota) {
            button.title = ""
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            button.image = statusIcon
            button.imagePosition = .imageLeading
            button.title = quota ?? (button.image == nil ? L10n.text("status.account") : "")
            button.font = .menuBarFont(ofSize: 0)
        }
        button.setAccessibilityLabel([L10n.text("accessibility.statusItem"), quota]
            .compactMap { $0 }.joined(separator: "，"))
    }

    @objc private func setStatusBarUsageMode(_ sender: NSMenuItem) {
        guard !busy, let value = sender.representedObject as? String,
              let mode = StatusBarUsageMode(rawValue: value) else { return }
        statusBarUsagePreference.mode = mode
        usage.statusBarUsageModeDidChange()
        rebuildMenu()
    }

    private func failureTitle(_ failure: UsageFailure) -> String? {
        switch failure {
        case .expired: return L10n.text("usage.failure.signInAgain")
        case .forbidden: return L10n.text("usage.badge.unavailable")
        case .throttled: return L10n.text("usage.badge.tryLater")
        case .unavailable: return L10n.text("usage.badge.updateFailed")
        case .unsupported: return nil
        }
    }

    @objc private func accountLoadError() {
        notify(L10n.text("alert.accountLoadFailed.title"), usage.loadError ?? L10n.text("alert.accountLoadFailed.message"))
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
        name.setAccessibilityLabel(L10n.text("accessibility.account.deleteNameCopyable"))
        name.translatesAutoresizingMaskIntoConstraints = false
        let nameContainer = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 44))
        nameContainer.addSubview(name)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: nameContainer.leadingAnchor),
            name.trailingAnchor.constraint(equalTo: nameContainer.trailingAnchor),
            name.centerYAnchor.constraint(equalTo: nameContainer.centerYAnchor)
        ])
        let alert = makeAlert(L10n.text("alert.deleteAccount.title"), account.identity == usage.currentIdentity
            ? L10n.text("alert.deleteAccount.currentMessage")
            : L10n.text("alert.deleteAccount.savedMessage"))
        alert.alertStyle = .warning
        alert.accessoryView = nameContainer
        alert.addButton(withTitle: L10n.text("common.cancel"))
        let delete = alert.addButton(withTitle: L10n.text("alert.deleteAccount.confirm"))
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
            ? L10n.text("alert.switchAccount.desktopMessage")
            : L10n.text("alert.switchAccount.cliMessage")
        let alert = makeAlert(L10n.text("alert.switchAccount.title", account.label), details)
        AlertButtons.addConfirmation(to: alert, cancelTitle: L10n.text("common.cancel"),
            confirmTitle: hasDesktopApp ? L10n.text("alert.switchAccount.confirmAndReopen")
                : L10n.text("alert.switchAccount.confirm"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        perform { [self] in try await change(to: target) }
    }

    @objc private func addAccount() {
        let alert = makeAlert(L10n.text("alert.addAccount.title"), L10n.text("alert.addAccount.message"))
        alert.addButton(withTitle: L10n.text("login.continue"))
        alert.addButton(withTitle: L10n.text("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performLogin(expectedIdentity: nil)
    }

    @objc private func reauthenticateAccount(_ sender: NSMenuItem) {
        guard !busy, let target = sender.representedObject as? String,
              let account = usage.accounts.first(where: { $0.identity == target }),
              usage.states[target]?.failure == .expired else { return }
        let alert = makeAlert(L10n.text("alert.reauthenticate.title", account.label), L10n.text("alert.reauthenticate.message"))
        alert.addButton(withTitle: L10n.text("login.continue"))
        alert.addButton(withTitle: L10n.text("common.cancel"))
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
        notify(expectedIdentity == nil ? L10n.text("notice.accountAdded.title") : L10n.text("notice.accountReauthenticated.title"),
               L10n.text("notice.accountReady.message", account.label))
    }

    private func change(to target: String) async throws {
        let file = try runtime.authFile(createDirectory: true)
        if let current = try file.read(), try AuthSnapshot(current).identity == target {
            notify(L10n.text("notice.alreadyUsing.title"), L10n.text("notice.alreadyUsing.message"))
            return
        }
        var book = try vault.load()
        if !book.accounts.contains(where: { $0.identity == target }) {
            throw SwitchError(localized: "error.account.notFoundReadd")
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
        notify(L10n.text("notice.accountSwitched.title"),
               hasDesktopApp ? L10n.text("notice.accountSwitched.desktopMessage") : L10n.text("notice.accountSwitched.cliMessage"))
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
        let alert = makeAlert(L10n.text("alert.forceQuit.title"),
            L10n.text("alert.forceQuit.message", list))
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.text("alert.forceQuit.cancel"))
        alert.addButton(withTitle: L10n.text("alert.forceQuit.confirm"))
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
        alert.addButton(withTitle: L10n.text("common.ok"))
        alert.runModal()
    }

    private func show(_ error: Error) {
        let message = (error as? SwitchError)?.message ?? L10n.text("error.generic.tryAgain")
        notify(L10n.text("error.generic.title"), message)
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
