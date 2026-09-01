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
            throw SwitchError("无法读取账号备份。请解锁登录钥匙串并允许本工具访问；未修改当前登录。")
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
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "ChatGPT / Codex 账号切换备份"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw SwitchError("钥匙串保存失败，未修改当前登录或已有账号备份。")
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
            throw SwitchError("工具目录含符号链接。")
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw SwitchError("工具目录权限不安全。")
        }
        let fd = open(directory.appendingPathComponent("instance.lock").path,
                      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SwitchError("无法锁定工具实例。") }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            close(fd)
            throw SwitchError("工具锁文件权限不安全。")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw SwitchError("账号切换工具已经在运行，请使用菜单栏中的“账号”。")
        }
        lockDescriptor = fd
    }

    func desktopApp() throws -> URL? {
        guard FileManager.default.fileExists(atPath: appURL.path) else { return nil }
        guard let bundle = Bundle(url: appURL), bundle.bundleIdentifier == "com.openai.codex",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "26.825.51511" else {
            throw SwitchError("当前客户端不是已检查的 26.825.51511 版本。请先复核兼容性，工具不会直接替换认证。")
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule = "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\" and identifier \"com.openai.codex\""
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw SwitchError("官方客户端签名校验失败。")
        }
        return appURL
    }

    func authFile(createDirectory: Bool = false) throws -> AuthFile {
        let env = ProcessInfo.processInfo.environment
        for key in ["CODEX_HOME", "CODEX_ELECTRON_USER_DATA_PATH", "CODEX_ACCESS_TOKEN",
                    "CODEX_AUTH_JSON", "OPENAI_API_KEY"] {
            if let value = env[key], !value.isEmpty {
                throw SwitchError("工具检测到自定义认证或启动环境。Prism 仅管理默认登录环境。")
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
                throw SwitchError("无法确认客户端进程身份，未修改认证。")
            }
            roots.append(entry)
        }
        try await shutdown.quit(roots: roots, initialSnapshot: snapshot, operations: ShutdownOperations(
            read: NativeProcesses.snapshot,
            requestQuit: {
                for app in apps where !app.isTerminated {
                    guard app.terminate() || app.isTerminated else {
                        throw SwitchError("客户端拒绝退出请求，未修改认证。")
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
                    continuation.resume(throwing: SwitchError("未能启动官方客户端。"))
                } else { continuation.resume() }
            }
        }
    }
}
