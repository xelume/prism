import AppKit
import Security
import LocalAuthentication
import Darwin

final class KeychainVault {
    private let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.chatgptAccountSwitcher",
        kSecAttrAccount as String: "accountBook-v1",
        kSecAttrSynchronizable as String: false
    ]

    func load(allowInteraction: Bool = true) throws -> AccountBook {
        var request = query
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            request[kSecUseAuthenticationContext as String] = context
        }
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return AccountBook() }
        guard status == errSecSuccess, let data = result as? Data,
              let book = try? JSONDecoder().decode(AccountBook.self, from: data) else {
            throw SwitchError(localized: "error.keychain.loadFailed")
        }
        try book.validate()
        return book
    }

    func save(_ book: AccountBook) throws {
        try book.validate()
        let data = try JSONEncoder().encode(book)
        let values = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            guard let label = Bundle.main.object(forInfoDictionaryKey: "PrismKeychainItemLabel") as? String,
                  !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SwitchError(localized: "error.keychain.saveFailed")
            }
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = label
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw SwitchError(localized: "error.keychain.saveFailed")
        }
    }

}
@MainActor
final class MacRuntime {
    let appURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
    let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    private var lockDescriptor: Int32 = -1
    private let shutdown = ClientShutdown()

    func lock() throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ChatGPT Account Switcher")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL else {
            throw SwitchError(localized: "error.runtime.reinstall")
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw SwitchError(localized: "error.runtime.invalidPermissionsReinstall")
        }
        let fd = open(directory.appendingPathComponent("instance.lock").path,
                      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SwitchError(localized: "error.runtime.quitAndRetry") }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            close(fd)
            throw SwitchError(localized: "error.runtime.invalidPermissionsReinstall")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw SwitchError(localized: "error.runtime.alreadyRunning")
        }
        lockDescriptor = fd
    }

    func desktopApp() throws -> URL? {
        guard FileManager.default.fileExists(atPath: appURL.path) else { return nil }
        guard let bundle = Bundle(url: appURL), bundle.bundleIdentifier == "com.openai.codex" else {
            throw SwitchError(localized: "error.runtime.chatgptUnrecognized")
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule = "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\" and identifier \"com.openai.codex\""
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw SwitchError(localized: "error.runtime.chatgptUnverified")
        }
        return appURL
    }

    func authFile(createDirectory: Bool = false) throws -> AuthFile {
        let env = ProcessInfo.processInfo.environment
        for key in ["CODEX_HOME", "CODEX_ELECTRON_USER_DATA_PATH", "CODEX_ACCESS_TOKEN",
                    "CODEX_AUTH_JSON", "OPENAI_API_KEY"] {
            if let value = env[key], !value.isEmpty {
                throw SwitchError(localized: "error.runtime.customCodexHomeUnsupported")
            }
        }
        if createDirectory, !FileManager.default.fileExists(atPath: home.path) {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        let file = try AuthFile(home: home)
        try file.checkConfiguration()
        return file
    }

    func currentAuth() throws -> Data? {
        guard FileManager.default.fileExists(atPath: home.path) else { return nil }
        return try authFile().read()
    }

    func codexExecutable() throws -> URL {
        var paths: [String] = []
        if let app = try desktopApp() {
            paths.append(app.appendingPathComponent("Contents/Resources/codex").path)
        }
        let environment = ProcessInfo.processInfo.environment
        paths += (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        paths += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                  userHome.appendingPathComponent(".local/bin/codex").path,
                  userHome.appendingPathComponent(".volta/bin/codex").path,
                  userHome.appendingPathComponent(".asdf/shims/codex").path,
                  userHome.appendingPathComponent(".local/share/mise/shims/codex").path]
        let nodeVersions = userHome.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(at: nodeVersions,
                includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            let newestFirst = versions.sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            paths += newestFirst.map { $0.appendingPathComponent("bin/codex").path }
        }
        return try CodexExecutable.resolve(configuredPath: environment["CODEX_CLI_PATH"], searchPaths: paths)
    }

    func requireStopped() throws {
        try shutdown.requireStopped(NativeProcesses.snapshot())
    }

    func quitClient(confirmForce: @escaping ([ProcessEntry]) -> Bool) async throws {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        let snapshot = try NativeProcesses.snapshot()
        var roots: [ProcessEntry] = []
        for app in apps where !app.isTerminated {
            guard let entry = snapshot.first(where: { $0.pid == app.processIdentifier }),
                  entry.executable == app.executableURL?.path else {
                if app.isTerminated { continue }
                throw SwitchError(localized: "error.runtime.quitStatusUnknown")
            }
            roots.append(entry)
        }
        try await shutdown.quit(roots: roots, initialSnapshot: snapshot, operations: ShutdownOperations(
            read: NativeProcesses.snapshot,
            requestQuit: {
                for app in apps where !app.isTerminated {
                    guard app.terminate() || app.isTerminated else {
                        throw SwitchError(localized: "error.runtime.chatgptStillRunning")
                    }
                }
            },
            signal: NativeProcesses.signal,
            confirmForce: confirmForce,
            now: { ProcessInfo.processInfo.systemUptime },
            pause: { try await Task.sleep(nanoseconds: 200_000_000) }
        ))
    }

    func launch() async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
                if error != nil || app == nil {
                    continuation.resume(throwing: SwitchError(localized: "error.runtime.relaunchFailedAfterSwitch"))
                } else { continuation.resume() }
            }
        }
    }
}
