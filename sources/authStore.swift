import Foundation
import CryptoKit
import Darwin

struct SwitchError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// JWT claims identify local snapshots only; the official client validates authentication.
struct AuthSnapshot {
    let data: Data
    let identity: String
    let accountID: String
    let accessToken: String
    let email: String?

    init(_ data: Data) throws {
        guard data.count < 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["auth_mode"] as? String == "chatgpt",
              object["OPENAI_API_KEY"] == nil || object["OPENAI_API_KEY"] is NSNull,
              let tokens = object["tokens"] as? [String: Any],
              let account = tokens["account_id"] as? String, !account.isEmpty,
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty,
              let id = tokens["id_token"] as? String,
              let claims = Self.claims(id),
              let subject = claims["sub"] as? String, !subject.isEmpty
        else { throw SwitchError("当前登录方式不受支持，请使用 ChatGPT 账号登录。") }
        self.data = data
        self.accountID = account
        self.accessToken = access
        self.email = Self.email(from: claims)
        self.identity = SHA256.hash(data: Data((account + "\u{0}" + subject).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func email(from claims: [String: Any]) -> String? {
        guard let raw = claims["email"] as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 80,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              let separator = value.firstIndex(of: "@"),
              separator == value.lastIndex(of: "@"),
              separator != value.startIndex,
              value.index(after: separator) != value.endIndex else { return nil }
        return value
    }

    private static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let bytes = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }
}

struct SavedAccount: Codable {
    let identity: String
    var label: String
    var auth: Data
}

struct AccountBook: Codable {
    var version = 1
    var accounts: [SavedAccount] = []

    mutating func remember(_ snapshot: AuthSnapshot, label: String? = nil) {
        if let index = accounts.firstIndex(where: { $0.identity == snapshot.identity }) {
            accounts[index].auth = snapshot.data
            if let label { accounts[index].label = label }
            else if let email = snapshot.email { accounts[index].label = email }
        } else {
            accounts.append(SavedAccount(identity: snapshot.identity,
                label: label ?? snapshot.email ?? "账号 \(accounts.count + 1)", auth: snapshot.data))
        }
    }

    func validate() throws {
        guard version == 1, accounts.count <= 100,
              Set(accounts.map(\.identity)).count == accounts.count else {
            throw SwitchError("已保存的账号信息无法识别。")
        }
        for account in accounts {
            guard try AuthSnapshot(account.auth).identity == account.identity,
                  !account.label.isEmpty, account.label.count <= 80 else {
                throw SwitchError("已保存的账号信息已损坏。")
            }
        }
    }
}

// Open the existing directory by descriptor and reject symlinks, unsafe permissions,
// and cross-user files. All writes are confined to auth.json in this directory.
final class AuthFile {
    private let directory: Int32

    init(home: URL) throws {
        guard home.resolvingSymlinksInPath().standardizedFileURL == home.standardizedFileURL else {
            throw SwitchError("当前账号存储位置不受支持。")
        }
        let fd = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SwitchError("无法读取当前账号。请先登录 ChatGPT 或 Codex，再试一次。") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            close(fd)
            throw SwitchError("当前账号文件权限异常。")
        }
        directory = fd
    }

    deinit { close(directory) }

    func read() throws -> Data? { try readFile("auth.json", secret: true) }

    private func readFile(_ name: String, secret: Bool) throws -> Data? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw SwitchError("无法安全地读取账号或配置。请检查文件权限后再试。")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & (secret ? 0o077 : 0o022) == 0,
              info.st_size < 1_048_576 else {
            throw SwitchError("账号或配置文件存在异常。")
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw SwitchError("无法读取当前账号。请稍后再试。")
            }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count < 1_048_576 else { throw SwitchError("当前账号文件异常。") }
        }
        return result
    }

    func checkConfiguration() throws {
        guard let data = try readFile("config.toml", secret: false) else { return }
        guard let text = String(data: data, encoding: .utf8) else { throw SwitchError("Codex 配置文件无法识别。") }
        // The supported packaged client fixes auth storage to auth.json. Reject an
        // explicit conflicting policy, but do not inspect stale OS keychain entries.
        let sensitiveKeys = ["cli_auth_credentials_store", "forced_login_method",
            "forced_chatgpt_workspace_id", "forced_chatgpt_workspace_ids", "secrets_store",
            "secret_auth_storage"]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            for key in sensitiveKeys where line.contains(key) {
                if key == "cli_auth_credentials_store",
                   line.range(of: #"^cli_auth_credentials_store\s*=\s*['\"]file['\"]\s*(#.*)?$"#,
                              options: .regularExpression) != nil { continue }
                throw SwitchError("自定义 Codex 登录设置暂不受支持。")
            }
        }
    }

    func replace(with data: Data?, expected: Data?) throws {
        guard try read() == expected else { throw SwitchError("账号已被其他应用更改，请结束其他 Codex 任务后再试。") }
        guard let data else {
            if expected != nil, unlinkat(directory, "auth.json", 0) != 0 {
                throw SwitchError("无法退出当前账号，请稍后再试。")
            }
            _ = fsync(directory)
            return
        }
        _ = try AuthSnapshot(data)
        let temporary = ".account-switch-" + UUID().uuidString
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SwitchError("无法准备账号切换。当前账号没有改变。") }
        defer { close(fd); _ = unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SwitchError("无法保存所选账号。当前账号没有改变。") }
                offset += count
            }
        }
        guard fsync(fd) == 0, try read() == expected else {
            throw SwitchError("账号已被其他应用更改，请结束其他 Codex 任务后再试。")
        }
        guard renameat(directory, temporary, directory, "auth.json") == 0 else {
            throw SwitchError("无法切换账号，请稍后再试。")
        }
        _ = fsync(directory)
    }
}

struct AuthChange {
    let previous: Data?
    let desired: Data?
}

// Persist the outgoing refreshed credentials before changing the live file.
// Vault failure must prevent any change to the active account.
func prepareChange(current: Data?, target: String?, book: inout AccountBook,
                   persist: (AccountBook) throws -> Void) throws -> AuthChange {
    try book.validate()
    if let current { book.remember(try AuthSnapshot(current)) }
    let desired: Data?
    if let target {
        guard let account = book.accounts.first(where: { $0.identity == target }) else {
            throw SwitchError("找不到所选账号的已保存信息，请重新添加这个账号。")
        }
        desired = account.auth
    } else { desired = nil }
    try persist(book)
    return AuthChange(previous: current, desired: desired)
}

@MainActor
func applyChange(_ change: AuthChange, file: AuthFile,
                 beforeWrite: () throws -> Void, launch: () async throws -> Void) async throws {
    try beforeWrite()
    try file.replace(with: change.desired, expected: change.previous)
    do { try await launch() }
    catch {
        do {
            try beforeWrite()
            try file.replace(with: change.previous, expected: change.desired)
        } catch {
            throw SwitchError("ChatGPT 无法重新打开，Prism 也无法自动切回原账号。已保存的账号仍然安全；请结束所有 Codex 任务，再从 Prism 选择原账号。")
        }
        throw SwitchError("ChatGPT 无法重新打开，Prism 已切回原账号。你可以手动打开 ChatGPT。")
    }
}
