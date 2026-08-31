import Foundation
import Darwin

private func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try condition() else { throw SwitchError("Assertion failed: " + label) }
}

private func rejects(_ label: String, _ operation: () throws -> Void) throws {
    do { try operation() }
    catch { return }
    throw SwitchError("Expected rejection: " + label)
}

private func fakeAuth(account: String, subject: String = "test-person", revision: String = "initial") throws -> Data {
    let claims = try JSONSerialization.data(withJSONObject: ["sub": subject])
    let payload = claims.base64EncodedString().replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    return try JSONSerialization.data(withJSONObject: [
        "auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(),
        "tokens": ["account_id": account, "access_token": "SIMULATED-" + revision,
                   "refresh_token": "SIMULATED-refresh-" + revision,
                   "id_token": "SIMULATED." + payload + ".NOT-A-SIGNATURE"],
        "last_refresh": revision, "preserved_future_field": ["test": true]
    ], options: [.sortedKeys])
}

func runTests() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("account-switch-tests-" + UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: root) }
    let file = try AuthFile(home: root)
    let a = try fakeAuth(account: "simulated-a")
    let refreshed = try fakeAuth(account: "simulated-a", revision: "refreshed")
    let b = try fakeAuth(account: "simulated-b")
    let identityA = try AuthSnapshot(a).identity
    let identityB = try AuthSnapshot(b).identity
    try check(AuthSnapshot(refreshed).identity == identityA, "refresh preserves identity")
    try check(AuthSnapshot(try fakeAuth(account: "simulated-a", subject: "another-user")).identity != identityA,
              "different users in same workspace stay separate")
    try rejects("malformed JSON") { _ = try AuthSnapshot(Data("broken".utf8)) }
    try rejects("API key login") {
        _ = try AuthSnapshot(JSONSerialization.data(withJSONObject: ["auth_mode": "apikey", "OPENAI_API_KEY": "SIMULATED"]))
    }

    var book = AccountBook()
    book.remember(try AuthSnapshot(a), label: "A")
    book.remember(try AuthSnapshot(b), label: "B")
    var persisted = AccountBook()
    try file.replace(with: refreshed, expected: nil)
    let config = root.appendingPathComponent("config.toml")
    let configData = Data("model = 'keep-this'\n".utf8)
    try configData.write(to: config)
    let tasks = root.appendingPathComponent("task-placeholder")
    try Data("unchanged-task".utf8).write(to: tasks)
    let change = try prepareChange(current: file.read(), target: identityB, book: &book, persist: { persisted = $0 })
    try check(persisted.accounts.first(where: { $0.identity == identityA })?.auth == refreshed,
              "persist refreshed outgoing token before replacement")
    try file.replace(with: change.desired, expected: change.previous)
    try check(file.read() == b, "switch A to B")
    try check(Data(contentsOf: config) == configData, "configuration unchanged")
    try check(Data(contentsOf: tasks) == Data("unchanged-task".utf8), "tasks unchanged")

    // Simulate a failed launch: restore only if the desired snapshot is still current.
    try file.replace(with: change.previous, expected: change.desired)
    try check(file.read() == refreshed, "launch failure rollback")
    try rejects("concurrent external login") { try file.replace(with: a, expected: b) }
    try check(file.read() == refreshed, "race leaves external auth untouched")

    var failedBook = book
    try rejects("vault write failure") {
        let failed = try prepareChange(current: file.read(), target: identityB, book: &failedBook,
                                       persist: { _ in throw SwitchError("simulated vault failure") })
        try file.replace(with: failed.desired, expected: failed.previous)
    }
    try check(file.read() == refreshed, "vault failure leaves active auth untouched")

    let clear = try prepareChange(current: file.read(), target: nil, book: &book, persist: { persisted = $0 })
    try file.replace(with: clear.desired, expected: clear.previous)
    try check(file.read() == nil, "new-account screen clears only auth")
    try check(persisted.accounts.contains(where: { $0.auth == refreshed }), "clear has durable outgoing backup")
    let restore = try prepareChange(current: nil, target: identityA, book: &book, persist: { _ in })
    try file.replace(with: restore.desired, expected: nil)
    try check(file.read() == refreshed, "restore after canceled login uses newest tokens")
    var info = stat()
    try check(lstat(root.appendingPathComponent("auth.json").path, &info) == 0 && info.st_mode & 0o777 == 0o600,
              "restored auth is owner-only")
    let same = try prepareChange(current: refreshed, target: identityA, book: &book, persist: { _ in })
    try check(same.desired == refreshed, "select current account never restores stale snapshot")
    let contents = try manager.contentsOfDirectory(atPath: root.path)
    try check(!contents.contains(where: { $0.hasPrefix(".account-switch-") }), "no temporary credential leftovers")

    var corrupt = book
    corrupt.accounts[0].auth = b
    try rejects("mismatched vault identity") { try corrupt.validate() }
    corrupt = book
    corrupt.version = 2
    try rejects("unknown backup format") { try corrupt.validate() }
    try rejects("missing target") {
        _ = try prepareChange(current: refreshed, target: "missing", book: &book, persist: { _ in })
    }

    try file.checkConfiguration()
    try Data("cli_auth_credentials_store = 'file' # explicit\n".utf8).write(to: config)
    try file.checkConfiguration()
    for line in ["cli_auth_credentials_store = 'auto'", "cli_auth_credentials_store = 'keyring'",
                 "forced_chatgpt_workspace_id = 'SIMULATED'", "'cli_auth_credentials_store' = 'auto'"] {
        try Data(line.utf8).write(to: config)
        try rejects("custom auth config") { try file.checkConfiguration() }
    }
    let authURL = root.appendingPathComponent("auth.json")
    try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: authURL.path)
    try rejects("world-readable credentials") { _ = try file.read() }
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    try manager.removeItem(at: authURL)
    try manager.createSymbolicLink(at: authURL, withDestinationURL: tasks)
    try rejects("auth symlink read") { _ = try file.read() }
    try rejects("auth symlink overwrite") { try file.replace(with: a, expected: nil) }
    try check(Data(contentsOf: tasks) == Data("unchanged-task".utf8), "symlink target untouched")
    let alias = root.appendingPathComponent("homeAlias")
    try manager.createSymbolicLink(at: alias, withDestinationURL: root)
    try rejects("home symlink") { _ = try AuthFile(home: alias) }
    try check(ProcessEntry(pid: 1, executable: "/tmp/extension/codex").isCodex, "IDE codex recognized")
    try check(ProcessEntry(pid: 1, executable: "/tmp/codex-code-mode-host").isCodex, "background helper recognized")
    try check(!ProcessEntry(pid: 1, executable: "/tmp/Prism").isCodex, "switcher excluded")
    print("PASS: identity, refreshed backups, switch, rollback, concurrent modification, vault failure, add/cancel, permissions, configuration, symlinks, process classification")
}

@MainActor
func runTransitionTests() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("account-transition-tests-" + UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: root) }
    let file = try AuthFile(home: root)
    let a = try fakeAuth(account: "simulated-a")
    let b = try fakeAuth(account: "simulated-b")
    let external = try fakeAuth(account: "simulated-external")
    try file.replace(with: a, expected: nil)
    let change = AuthChange(previous: a, desired: b)
    var launched = false
    do {
        try await applyChange(change, file: file,
            beforeWrite: { throw SwitchError("simulated running process") }, launch: { launched = true })
        throw SwitchError("Expected process guard failure")
    } catch {}
    try check(!launched && file.read() == a, "running processes block writes and launch")
    var checks = 0
    do {
        try await applyChange(change, file: file, beforeWrite: { checks += 1 }, launch: {
            try check(file.read() == b, "launch sees new auth")
            throw SwitchError("simulated launch error")
        })
        throw SwitchError("Expected launch error")
    } catch {}
    try check(checks == 2 && file.read() == a, "actual orchestrator rolls back launch failure")
    do {
        try await applyChange(change, file: file, beforeWrite: {}, launch: {
            try file.replace(with: external, expected: b)
            throw SwitchError("simulated external login and launch error")
        })
    } catch {}
    try check(file.read() == external, "rollback never overwrites newer external login")
    try file.replace(with: a, expected: external)
    var stopped = true
    do {
        try await applyChange(change, file: file, beforeWrite: {
            guard stopped else { throw SwitchError("process started during launch") }
        }, launch: {
            stopped = false
            throw SwitchError("launch partially succeeded")
        })
    } catch {}
    try check(file.read() == b, "no rollback under live process")
    try file.replace(with: a, expected: b)
    try await applyChange(change, file: file, beforeWrite: {}, launch: { launched = true })
    try check(launched && file.read() == b, "successful transition keeps target auth")
    print("PASS: real transition orchestration with simulated launch failures, late process start, and external login")
}
