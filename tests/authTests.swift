import Foundation
import Darwin
import Security

private func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try condition() else { throw SwitchError("Assertion failed: " + label) }
}
private func rejects(_ label: String, _ operation: () throws -> Void) throws {
    do { try operation() }
    catch { return }
    throw SwitchError("Expected rejection: " + label)
}

private func fakeAuth(account: String, subject: String = "test-person", revision: String = "initial",
                      email: String? = nil, plan: String? = nil) throws -> Data {
    var payloadClaims: [String: Any] = ["sub": subject]
    if let email { payloadClaims["email"] = email }
    if let plan {
        payloadClaims["https://api.openai.com/auth"] = ["chatgpt_plan_type": plan,
            "chatgpt_account_id": account]
    }
    let claims = try JSONSerialization.data(withJSONObject: payloadClaims)
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
    let keychainData = Data("simulated-keychain-data".utf8)
    let keychainValues = KeychainVault.itemValues(for: keychainData)
    try check(keychainValues[kSecAttrLabel as String] as? String == "Prism",
              "new and existing keychain items use a stable label")
    try check(keychainValues[kSecValueData as String] as? Data == keychainData,
              "keychain updates preserve the encoded account data")
    try check(KeychainVault.labelValues[kSecAttrLabel as String] as? String == "Prism"
              && KeychainVault.labelValues[kSecValueData as String] == nil,
              "successful reads migrate only the keychain label")

    let manager = FileManager.default
    let root = manager.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("account-switch-tests-" + UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: root) }
    let file = try AuthFile(home: root)
    let fakeCLI = root.appendingPathComponent("codex")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeCLI)
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
    try check(try CodexExecutable.resolve(configuredPath: fakeCLI.path, searchPaths: []).path == fakeCLI.path,
              "configured standalone CLI is accepted")
    try manager.setAttributes([.posixPermissions: 0o722], ofItemAtPath: fakeCLI.path)
    try rejects("writable standalone CLI") {
        _ = try CodexExecutable.resolve(configuredPath: fakeCLI.path, searchPaths: [])
    }
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
    try check(try CodexExecutable.resolve(configuredPath: nil, searchPaths: ["/missing/codex", fakeCLI.path]).path == fakeCLI.path,
              "standalone CLI search skips unusable candidates")
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

    let emailAuth = try AuthSnapshot(fakeAuth(account: "simulated-email", email: "person@example.com"))
    try check(emailAuth.email == "person@example.com", "email is read from the ID token")
    try check(emailAuth.isWorkspaceAccount == nil, "missing plan type remains unknown")
    for plan in ["team", "business", "enterprise", "edu", "education"] {
        let workspace = try AuthSnapshot(fakeAuth(account: "simulated-" + plan, plan: plan))
        try check(workspace.isWorkspaceAccount == true, plan + " is classified as a workspace account")
    }
    for plan in ["free", "plus", "pro"] {
        let personal = try AuthSnapshot(fakeAuth(account: "simulated-" + plan, plan: plan))
        try check(personal.isWorkspaceAccount == false, plan + " is classified as a personal account")
    }
    try check(try AuthSnapshot(fakeAuth(account: "simulated-unknown-plan", plan: "future-plan"))
        .isWorkspaceAccount == nil, "unknown plan type is not guessed")
    let sharedEmailPersonal = try AuthSnapshot(fakeAuth(account: "simulated-personal-workspace",
        email: "shared@example.com", plan: "plus"))
    let sharedEmailTeam = try AuthSnapshot(fakeAuth(account: "simulated-team-workspace",
        email: "shared@example.com", plan: "business"))
    try check(sharedEmailPersonal.identity != sharedEmailTeam.identity
        && sharedEmailPersonal.isWorkspaceAccount == false && sharedEmailTeam.isWorkspaceAccount == true,
        "same email keeps personal and workspace accounts distinct")
    let invalidEmail = try AuthSnapshot(fakeAuth(account: "simulated-invalid-email", email: "not-an-email"))
    try check(invalidEmail.email == nil, "invalid email is ignored")
    let malformedEmail = try AuthSnapshot(fakeAuth(account: "simulated-malformed-email", email: "one@two@example.com"))
    try check(malformedEmail.email == nil, "email with multiple separators is ignored")
    let longEmail = String(repeating: "a", count: 69) + "@example.com"
    try check(try AuthSnapshot(fakeAuth(account: "simulated-long-email", email: longEmail)).email == nil,
              "email longer than the label limit is ignored")

    var namedBook = AccountBook()
    namedBook.remember(emailAuth)
    try check(namedBook.accounts.first?.label == "person@example.com", "new account uses email label")
    let refreshedEmailAuth = try AuthSnapshot(fakeAuth(account: "simulated-email", revision: "refreshed",
                                                        email: "updated@example.com"))
    namedBook.remember(refreshedEmailAuth)
    try check(namedBook.accounts.first?.label == "updated@example.com", "refresh updates email label")
    namedBook.remember(invalidEmail)
    try check(namedBook.accounts.last?.label == L10n.text("account.defaultName", 2), "missing email uses numbered label")

    namedBook.accounts[0].label = "工作账号"
    namedBook.accounts[0].hasCustomLabel = true
    namedBook.remember(refreshedEmailAuth)
    try check(namedBook.accounts.first?.label == "updated@example.com" &&
              namedBook.accounts.first?.hasCustomLabel == false,
              "refresh replaces a retired custom label with the account email")

    var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(namedBook)) as! [String: Any]
    var legacyAccounts = legacyObject["accounts"] as! [[String: Any]]
    for index in legacyAccounts.indices { legacyAccounts[index].removeValue(forKey: "hasCustomLabel") }
    legacyObject["accounts"] = legacyAccounts
    let legacyBook = try JSONDecoder().decode(AccountBook.self,
        from: JSONSerialization.data(withJSONObject: legacyObject))
    try check(legacyBook.accounts.count == namedBook.accounts.count &&
              legacyBook.accounts.allSatisfy { $0.hasCustomLabel == nil },
              "keychain records created before custom labels remain decodable")
    var workspaceBook = AccountBook()
    workspaceBook.remember(sharedEmailPersonal)
    workspaceBook.remember(sharedEmailTeam)
    try check(workspaceBook.accounts.count == 2 && workspaceBook.accounts[0].isWorkspaceAccount == false
        && workspaceBook.accounts[1].isWorkspaceAccount == true,
        "saved accounts derive workspace classification from their login snapshot")

    var removableBook = namedBook
    let remainingAuth = removableBook.accounts.last!.auth
    let activeAuthBeforeRemoval = try file.read()
    try removableBook.remove(identity: emailAuth.identity)
    try check(removableBook.accounts.count == 1 && removableBook.accounts[0].auth == remainingAuth,
              "remove deletes only the selected backup")
    try check(file.read() == activeAuthBeforeRemoval,
              "removing a backup never changes the active auth file")
    try rejects("missing removal target") { try removableBook.remove(identity: "missing") }

    var loginBook = AccountBook()
    let loggedIn = try AccountLogin.remember(emailAuth.data, expectedIdentity: nil, in: &loginBook)
    try check(loggedIn.label == "person@example.com", "isolated login is saved with its email")
    let beforeMismatch = loginBook
    try rejects("different account during reauthentication") {
        _ = try AccountLogin.remember(invalidEmail.data, expectedIdentity: emailAuth.identity, in: &loginBook)
    }
    try check(loginBook.accounts.map(\.identity) == beforeMismatch.accounts.map(\.identity),
              "reauthentication mismatch leaves the account book unchanged")

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
                 "cli_auth_credentials_store = 'ephemeral'",
                 "forced_chatgpt_workspace_id = 'SIMULATED'", "secret_auth_storage = true",
                 "'cli_auth_credentials_store' = 'auto'"] {
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
    try check(!ProcessEntry(pid: 1,
        executable: "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Helpers/browser_crashpad_handler").isCodex,
        "ChatGPT crash reporter does not consume authentication")
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
    let stubbornCLI = root.appendingPathComponent("stubborn-codex")
    try Data("#!/bin/sh\nexec /usr/bin/python3 -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)'\n".utf8)
        .write(to: stubbornCLI)
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stubbornCLI.path)
    func loginDirectories() -> Set<String> {
        Set(((try? manager.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
            .filter { $0.hasPrefix("prism-account-login.") })
    }
    let directoriesBeforeCancel = loginDirectories()
    let canceledLogin = Task {
        try await AccountLogin.run(executable: stubbornCLI, timeout: 30, terminationGrace: 0.05)
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    canceledLogin.cancel()
    do {
        _ = try await canceledLogin.value
        throw SwitchError("Expected login cancellation")
    } catch is CancellationError { }
    try check(loginDirectories() == directoriesBeforeCancel, "cancel removes isolated login directory")
    let directoriesBeforeTimeout = loginDirectories()
    let timeoutStart = ProcessInfo.processInfo.systemUptime
    do {
        _ = try await AccountLogin.run(executable: stubbornCLI, timeout: 0.05, terminationGrace: 0.05)
        throw SwitchError("Expected login timeout")
    } catch is CancellationError {
        throw SwitchError("Timeout must not report user cancellation")
    } catch let error as SwitchError {
        try check(error.message == L10n.text("error.login.timedOut"),
                  "timeout reports its actual reason")
    }
    try check(ProcessInfo.processInfo.systemUptime - timeoutStart < 2,
              "timeout force-stops an unresponsive login process")
    try check(loginDirectories() == directoriesBeforeTimeout, "timeout removes isolated login directory")
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
    print("PASS: cancel/timeout login cleanup, transition orchestration, launch failures, late process start, and external login")
}
