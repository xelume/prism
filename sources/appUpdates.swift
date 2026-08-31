import AppKit
import Sparkle

@MainActor
// Sparkle's standard UI callbacks run on the main thread, but its Objective-C
// user-driver protocol does not yet carry Swift actor annotations.
final class AppUpdates: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    let installationGate = UpdateInstallationGate()
    var onChange: (() -> Void)?
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    private(set) var availableVersion: String?
    private(set) var configurationMessage: String?

    var canCheck: Bool {
        !installationGate.accountOperationInProgress && !installationGate.installationRequested
            && (controller?.updater.canCheckForUpdates ?? true)
    }
    var isConfigured: Bool { controller != nil && configurationMessage == nil }
    var automaticallyChecks: Bool { controller?.updater.automaticallyChecksForUpdates ?? false }
    var menuTitle: String {
        availableVersion.map { "更新至 \($0)…" } ?? "检查更新…"
    }

    func start() {
        guard controller == nil else { return }
        guard UpdateConfiguration(info: Bundle.main.infoDictionary ?? [:]) != nil else {
            configurationMessage = "此构建尚未配置更新签名公钥或 HTTPS 更新地址。请前往项目主页获取版本。"
            onChange?()
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        do {
            try controller.updater.start()
            observations = [
                controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor in self?.onChange?() }
                },
                controller.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor in self?.onChange?() }
                }
            ]
        } catch {
            configurationMessage = "更新器无法启动。请前往项目主页下载，或重新安装应用后重试。"
            self.controller = nil
        }
        onChange?()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard canCheck else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let message = configurationMessage {
            let alert = NSAlert()
            alert.messageText = "暂时无法检查更新"
            alert.informativeText = message
            alert.addButton(withTitle: "知道了")
            alert.addButton(withTitle: "打开项目主页")
            if alert.runModal() == .alertSecondButtonReturn { AboutWindow.openProject() }
            return
        }
        controller?.checkForUpdates(sender)
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        guard isConfigured else { return }
        controller?.updater.automaticallyChecksForUpdates = enabled
        onChange?()
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !installationGate.accountOperationInProgress else {
            throw NSError(domain: "local.chatgptAccountSwitcher.updates", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "正在处理账号，请完成后再检查更新。"])
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        installationGate.prepareInstallation()
        onChange?()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        installationGate.postponeInstallation(installHandler)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        installationGate.cancelInstallation()
        onChange?()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        // Canceling the UI can finish a cycle without an error callback.
        installationGate.cancelInstallation()
        onChange?()
    }

    // This app has no Dock icon. Surface scheduled updates in its existing menu
    // instead of taking keyboard focus away from another application.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
        onChange?()
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
        onChange?()
    }
}
