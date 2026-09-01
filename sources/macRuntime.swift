import AppKit
import Security
import LocalAuthentication
import CryptoKit
import Darwin

func codexAuthStoreRejection(for status: OSStatus) -> String? {
    switch status {
    case errSecSuccess, errSecItemNotFound:
        return nil
    case errSecInteractionNotAllowed:
        return "无法确认 Codex 的认证存储：钥匙串当前禁止交互或可能已锁定。请解锁登录钥匙串后重试；Prism 未修改当前登录。"
    case errSecAuthFailed:
        return "无法确认 Codex 的认证存储：macOS 拒绝了钥匙串访问。请检查 Prism 的钥匙串访问权限后重试；Prism 未修改当前登录。"
    case errSecNotAvailable:
        return "无法确认 Codex 的认证存储：当前无法使用系统钥匙串。请确认登录钥匙串可用后重试；Prism 未修改当前登录。"
    default:
        return "无法确认 Codex 的认证存储（系统错误 \(status)）。为避免切错账号，Prism 未修改当前登录。"
    }
}

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
            throw SwitchError("钥匙串保存失败，已停止切换。当前认证不会被替换。")
        }
    }

}

enum CodexAuthStoreKind: Equatable {
    case file
    case directKeychain
}

final class DirectKeychainAuthStore: CodexAuthStore {
    static let service = "Codex Auth"
    let account: String
    private let allowInteraction: Bool

    init(home: URL, allowInteraction: Bool) {
        let canonical = home.resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        account = "cli|" + digest.prefix(16)
        self.allowInteraction = allowInteraction
    }

    private func query(returnData: Bool = false, exactAccount: Bool = true,
                       matchLimit: Bool = true) -> [String: Any] {
        var request: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrSynchronizable as String: false
        ]
        if matchLimit { request[kSecMatchLimit as String] = kSecMatchLimitOne }
        if exactAccount { request[kSecAttrAccount as String] = account }
        if returnData { request[kSecReturnData as String] = true }
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            request[kSecUseAuthenticationContext as String] = context
        }
        return request
    }

    func probe(exactAccount: Bool = true) -> OSStatus {
        SecItemCopyMatching(query(exactAccount: exactAccount) as CFDictionary, nil)
    }

    func read() throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(returnData: true) as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SwitchError(Self.message(status, action: "读取"))
        }
        guard data.count < 1_048_576 else { throw SwitchError("Codex 钥匙串认证过大，Prism 已停止操作。") }
        return data
    }

    func replace(with data: Data?, expected: Data?) throws {
        guard try read() == expected else {
            throw SwitchError("Codex 钥匙串认证已被其他进程改变，已取消切换。请关闭 Codex 后重试。")
        }
        if let data {
            _ = try AuthSnapshot(data)
            let status: OSStatus
            if expected == nil {
                var item = query(matchLimit: false)
                item.removeValue(forKey: kSecUseAuthenticationContext as String)
                item[kSecValueData as String] = data
                item[kSecAttrLabel as String] = "Codex Auth"
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            } else {
                status = SecItemUpdate(query(matchLimit: false) as CFDictionary,
                    [kSecValueData as String: data] as CFDictionary)
            }
            guard status == errSecSuccess else { throw SwitchError(Self.message(status, action: "写入")) }
        } else if expected != nil {
            let status = SecItemDelete(query(matchLimit: false) as CFDictionary)
            guard status == errSecSuccess else { throw SwitchError(Self.message(status, action: "移除")) }
        }
        guard try read() == data else { throw SwitchError("Codex 钥匙串认证写入后校验失败，已停止操作。") }
    }

    private static func message(_ status: OSStatus, action: String) -> String {
        switch status {
        case errSecInteractionNotAllowed:
            return "无法\(action) Codex 钥匙串认证：钥匙串已锁定或禁止交互。请点击“授权并重试”。"
        case errSecAuthFailed:
            return "无法\(action) Codex 钥匙串认证：macOS 拒绝了访问。Prism 未修改当前登录。"
        case errSecNotAvailable:
            return "无法\(action) Codex 钥匙串认证：系统钥匙串当前不可用。Prism 未修改当前登录。"
        default:
            return "无法\(action) Codex 钥匙串认证（系统错误 \(status)）。Prism 未修改当前登录。"
        }
    }
}

struct CodexAuthAccess {
    let store: any CodexAuthStore
    let file: AuthFile
    let kind: CodexAuthStoreKind
    let preference: AuthStorePreference

    func validateConfiguration() throws {
        guard try file.credentialStorePreference() == preference else {
            throw SwitchError("认证存储配置已发生变化，已取消切换。请关闭 Codex 后重试。")
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

    func preflight(allowInteraction: Bool = true) throws -> CodexAuthAccess {
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
        let env = ProcessInfo.processInfo.environment
        for key in ["CODEX_HOME", "CODEX_CLI_PATH", "CODEX_ELECTRON_USER_DATA_PATH",
                    "CODEX_ACCESS_TOKEN", "CODEX_AUTH_JSON", "OPENAI_API_KEY"] {
            if let value = env[key], !value.isEmpty {
                throw SwitchError("工具检测到自定义认证或启动环境。第一版仅支持默认登录环境。")
            }
        }
        let file = try AuthFile(home: home)
        let preference = try file.credentialStorePreference()
        let keychain = DirectKeychainAuthStore(home: home, allowInteraction: allowInteraction)
        let directStatus = keychain.probe()
        let kind: CodexAuthStoreKind
        switch preference {
        case .file:
            kind = .file
        case .keyring:
            if directStatus != errSecSuccess && directStatus != errSecItemNotFound {
                throw SwitchError(codexAuthStoreRejection(for: directStatus)
                    ?? "无法确认 Codex 钥匙串认证。")
            }
            kind = .directKeychain
        case .auto, .unspecified:
            if directStatus == errSecSuccess {
                kind = .directKeychain
            } else if directStatus == errSecItemNotFound {
                let serviceStatus = keychain.probe(exactAccount: false)
                guard serviceStatus == errSecItemNotFound else {
                    throw SwitchError("检测到不属于默认 CODEX_HOME 的 Codex 钥匙串项目，或当前客户端使用了 Prism 尚不支持的 Secrets 后端。未修改当前登录。")
                }
                kind = .file
            } else {
                throw SwitchError(codexAuthStoreRejection(for: directStatus)
                    ?? "无法确认 Codex 钥匙串认证。")
            }
        }
        return CodexAuthAccess(store: kind == .file ? file : keychain,
            file: file, kind: kind, preference: preference)
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
