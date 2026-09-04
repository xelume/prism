import Foundation
import CryptoKit
import Darwin

struct SwitchError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    init(localized key: String, _ arguments: CVarArg...) { self.message = L10n.format(key, arguments) }
    var errorDescription: String? { message }
}

// JWT claims identify local snapshots only; the official client validates authentication.
struct AuthSnapshot {
    let data: Data
    let identity: String
    let accountID: String
    let accessToken: String
    let email: String?
    let isWorkspaceAccount: Bool?

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
        else { throw SwitchError(localized: "error.auth.unsupportedSignIn") }
        self.data = data
        self.accountID = account
        self.accessToken = access
        self.email = Self.email(from: claims)
        self.isWorkspaceAccount = Self.workspaceAccount(from: claims)
        self.identity = SHA256.hash(data: Data((account + "\u{0}" + subject).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func workspaceAccount(from claims: [String: Any]) -> Bool? {
        guard let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let raw = auth["chatgpt_plan_type"] as? String else { return nil }
        switch raw.lowercased() {
        case "team", "business", "enterprise", "edu", "education": return true
        case "free", "plus", "pro": return false
        default: return nil
        }
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
    var hasCustomLabel: Bool?

    var isWorkspaceAccount: Bool { (try? AuthSnapshot(auth).isWorkspaceAccount) == true }
}

struct AccountBook: Codable {
    var version = 1
    var accounts: [SavedAccount] = []

    mutating func remember(_ snapshot: AuthSnapshot, label: String? = nil) {
        if let index = accounts.firstIndex(where: { $0.identity == snapshot.identity }) {
            accounts[index].auth = snapshot.data
            if let label {
                accounts[index].label = label
                accounts[index].hasCustomLabel = false
            } else if let email = snapshot.email {
                accounts[index].label = email
                accounts[index].hasCustomLabel = false
            }
        } else {
            accounts.append(SavedAccount(identity: snapshot.identity,
                label: label ?? snapshot.email ?? L10n.text("account.defaultName", accounts.count + 1), auth: snapshot.data,
                hasCustomLabel: false))
        }
    }

    mutating func remove(identity: String) throws {
        guard let index = accounts.firstIndex(where: { $0.identity == identity }) else {
            throw SwitchError(localized: "error.account.notFoundReopenMenu")
        }
        accounts.remove(at: index)
    }

    func validate() throws {
        guard version == 1, accounts.count <= 100,
              Set(accounts.map(\.identity)).count == accounts.count else {
            throw SwitchError(localized: "error.account.savedDataUnrecognized")
        }
        for account in accounts {
            guard try AuthSnapshot(account.auth).identity == account.identity,
                  !account.label.isEmpty, account.label.count <= 80 else {
                throw SwitchError(localized: "error.account.savedDataDamaged")
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
            throw SwitchError(localized: "error.storage.unsupportedLocation")
        }
        let fd = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SwitchError(localized: "error.storage.readCurrentSignInFirst") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            close(fd)
            throw SwitchError(localized: "error.storage.invalidPermissions")
        }
        directory = fd
    }

    deinit { close(directory) }

    func read() throws -> Data? { try readFile("auth.json", secret: true) }

    private func readFile(_ name: String, secret: Bool) throws -> Data? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw SwitchError(localized: "error.storage.unsafeRead")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & (secret ? 0o077 : 0o022) == 0,
              info.st_size < 1_048_576 else {
            throw SwitchError(localized: "error.storage.invalidFile")
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw SwitchError(localized: "error.storage.readCurrentRetry")
            }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count < 1_048_576 else { throw SwitchError(localized: "error.storage.invalidAccountFile") }
        }
        return result
    }

    func checkConfiguration() throws {
        guard let data = try readFile("config.toml", secret: false) else { return }
        guard let text = String(data: data, encoding: .utf8) else { throw SwitchError(localized: "error.config.unrecognized") }
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
                throw SwitchError(localized: "error.config.customSignInUnsupported")
            }
        }
    }

    func replace(with data: Data?, expected: Data?) throws {
        guard try read() == expected else { throw SwitchError(localized: "error.account.changedExternally") }
        guard let data else {
            if expected != nil, unlinkat(directory, "auth.json", 0) != 0 {
                throw SwitchError(localized: "error.account.signOutFailed")
            }
            _ = fsync(directory)
            return
        }
        _ = try AuthSnapshot(data)
        let temporary = ".account-switch-" + UUID().uuidString
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SwitchError(localized: "error.account.switchPreparationFailed") }
        defer { close(fd); _ = unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SwitchError(localized: "error.account.saveSelectedFailed") }
                offset += count
            }
        }
        guard fsync(fd) == 0, try read() == expected else {
            throw SwitchError(localized: "error.account.changedExternally")
        }
        guard renameat(directory, temporary, directory, "auth.json") == 0 else {
            throw SwitchError(localized: "error.account.switchFailed")
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
            throw SwitchError(localized: "error.account.selectedBackupMissing")
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
            throw SwitchError(localized: "error.account.relaunchAndRollbackFailed")
        }
        throw SwitchError(localized: "error.account.relaunchFailedRolledBack")
    }
}
