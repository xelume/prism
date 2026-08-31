import Foundation

private func requireUsage(_ condition: @autoclosure () -> Bool, _ name: String) throws {
    if !condition() { throw SwitchError("Usage test failed: " + name) }
}

private func usageAuth(_ name: String, revision: String = "original") throws -> AuthSnapshot {
    let payload = Data("{\"sub\":\"SIMULATED-user\"}".utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
    return try AuthSnapshot(JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": [
        "account_id": name, "access_token": "SIMULATED-" + name + "-" + revision,
        "refresh_token": "SIMULATED-refresh", "id_token": "fake." + payload + ".fake"
    ]]))
}

private func decodeUsage(_ json: String) throws -> AccountUsage { try AccountUsage.decode(Data(json.utf8)) }

private func expectUsageFailure(_ expected: UsageFailure, _ operation: () throws -> Void) throws {
    do { try operation() }
    catch let error as UsageFailure {
        try requireUsage(error == expected, "failure classification")
        return
    }
    throw SwitchError("Usage test failed: expected failure")
}

private actor UsageProbe {
    var replies: [String: Result<AccountUsage, UsageFailure>] = [:]
    var calls: [String] = []
    var active = 0
    var peak = 0

    func reply(_ identity: String, _ result: Result<AccountUsage, UsageFailure>) { replies[identity] = result }
    func count() -> Int { calls.count }
    func peakCount() -> Int { peak }
    func fetch(_ auth: AuthSnapshot) async throws -> AccountUsage {
        calls.append(auth.accessToken)
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(nanoseconds: 2_000_000)
        return try (replies[auth.identity] ?? .failure(.unavailable)).get()
    }
}

private actor UsageGate {
    private var continuation: CheckedContinuation<AccountUsage, Never>?
    private var started = false
    func fetch() async -> AccountUsage {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func didStart() -> Bool { started }
    func finish(_ value: AccountUsage) { continuation?.resume(returning: value); continuation = nil }
}

@MainActor
private func waitForUsage(_ condition: () async -> Bool) async throws {
    for _ in 0..<2000 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw SwitchError("Usage test timed out")
}

@MainActor
func runUsageTests() async throws {
    let normal = try decodeUsage("""
    {"rate_limit":{"primary_window":{"used_percent":20.4,"limit_window_seconds":18000,"reset_at":2000000000},
    "secondary_window":{"used_percent":110,"limit_window_seconds":604800,"reset_at":2000600000}},
    "additional_rate_limits":[{"limit_name":"other-model","rate_limit":{"primary_window":{"used_percent":99,"limit_window_seconds":18000}}}]}
    """)
    try requireUsage(normal.fiveHour?.remainingPercent == 79, "fractional percent must not overstate remaining")
    try requireUsage(normal.week?.remainingPercent == 0, "over-quota clamps at zero")
    let swapped = try decodeUsage("""
    {"rate_limit":{"primary_window":{"used_percent":15,"limit_window_seconds":604800},
    "secondary_window":{"used_percent":25,"limit_window_seconds":18000}}}
    """)
    try requireUsage(swapped.week?.remainingPercent == 85 && swapped.fiveHour?.remainingPercent == 75, "duration mapping independent of slot")
    let other = try decodeUsage("{\"rate_limit\":{\"primary_window\":{\"used_percent\":5,\"limit_window_seconds\":900}}}")
    try requireUsage(other.week == nil && other.fiveHour == nil, "never relabel unknown windows")
    for invalid in ["{}", "{\"rate_limit\":null}", "not-json",
        "{\"rate_limit\":{\"primary_window\":{\"limit_window_seconds\":18000}}}",
        "{\"rate_limit\":{\"primary_window\":{\"used_percent\":-1,\"limit_window_seconds\":18000}}}",
        "{\"rate_limit\":{\"primary_window\":{\"used_percent\":true,\"limit_window_seconds\":18000}}}"] {
        try expectUsageFailure(.unsupported) { _ = try decodeUsage(invalid) }
    }
    let a = try usageAuth("SIMULATED-a"), b = try usageAuth("SIMULATED-b")
    let requestA = try UsageClient.request(for: a), requestB = try UsageClient.request(for: b)
    try requireUsage(requestA.url == UsageClient.endpoint && requestA.httpMethod == "GET", "fixed read-only endpoint")
    try requireUsage(requestA.value(forHTTPHeaderField: "Authorization") == "Bearer " + a.accessToken &&
        requestB.value(forHTTPHeaderField: "Authorization") == "Bearer " + b.accessToken &&
        requestA.value(forHTTPHeaderField: "ChatGPT-Account-Id") == a.accountID &&
        requestB.value(forHTTPHeaderField: "ChatGPT-Account-Id") == b.accountID, "account headers cannot bleed across requests")
    let injected = try usageAuth("SIMULATED-a\r\nInjected:yes")
    try expectUsageFailure(.unsupported) { _ = try UsageClient.request(for: injected) }
    for (code, failure) in [(401, UsageFailure.expired), (403, .forbidden), (404, .unsupported), (500, .unavailable), (302, .unavailable)] {
        try expectUsageFailure(failure) {
            try UsageClient.validate(HTTPURLResponse(url: UsageClient.endpoint, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
    }
    try expectUsageFailure(.throttled(900)) {
        try UsageClient.validate(HTTPURLResponse(url: UsageClient.endpoint, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "900"])!)
    }
    try expectUsageFailure(.unavailable) {
        try UsageClient.validate(HTTPURLResponse(url: URL(string: "https://example.invalid/")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let redirectTask = session.dataTask(with: requestA) // Never resumed; no network.
    var redirectBlocked = false
    UsageClient().urlSession(session, task: redirectTask,
        willPerformHTTPRedirection: HTTPURLResponse(url: UsageClient.endpoint, statusCode: 302, httpVersion: nil, headerFields: nil)!,
        newRequest: URLRequest(url: URL(string: "https://example.invalid/")!), completionHandler: { redirectBlocked = $0 == nil })
    try requireUsage(redirectBlocked, "never forward credentials on redirect")

    var book = AccountBook()
    book.remember(a, label: "A"); book.remember(b, label: "B")
    let latestA = try usageAuth("SIMULATED-a", revision: "latest")
    var loaded = try UsageAccounts(book: book, current: latestA.data)
    try requireUsage(loaded.accounts.first?.auth == latestA.data && book.accounts.first?.auth == a.data,
        "current token wins only in memory; saved book is unchanged")
    let unsaved = try UsageAccounts(book: book, current: usageAuth("SIMULATED-new").data)
    try requireUsage(unsaved.accounts.count == 3 && !unsaved.savedIdentities.contains(unsaved.currentIdentity!), "unsaved current account is visible but not switchable")
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    let probe = UsageProbe()
    await probe.reply(a.identity, .success(normal)); await probe.reply(b.identity, .success(swapped))
    let monitor = UsageMonitor(load: { loaded }, fetch: { try await probe.fetch($0) }, now: { clock })
    monitor.refreshOnMenuOpen(); monitor.refreshOnMenuOpen()
    try await waitForUsage { !monitor.refreshing }
    let firstCount = await probe.count()
    try requireUsage(firstCount == 2, "no overlapping refresh batches")
    try requireUsage(monitor.states[a.identity]?.value == normal && monitor.states[b.identity]?.value == swapped, "per-account cache isolation")
    monitor.refresh()
    try requireUsage(!monitor.refreshing, "cached batch is not polled before five minutes")
    monitor.refreshOnMenuOpen()
    try requireUsage(!monitor.refreshing, "reopening immediately uses cached usage")
    clock = clock.addingTimeInterval(29)
    monitor.refreshOnMenuOpen()
    try requireUsage(!monitor.refreshing, "menu cooldown lasts thirty seconds after completion")
    let cachedCount = await probe.count()
    try requireUsage(cachedCount == firstCount, "repeated opens during cooldown send no requests")
    clock = clock.addingTimeInterval(1)
    monitor.refreshOnMenuOpen()
    monitor.refreshOnMenuOpen()
    try await waitForUsage { !monitor.refreshing }
    let reopenedCount = await probe.count()
    try requireUsage(reopenedCount == firstCount + 2,
        "menu refresh starts at thirty seconds and coalesces in-flight requests")
    monitor.refreshOnMenuOpen()
    try requireUsage(!monitor.refreshing, "completed menu refresh starts a new cooldown")
    clock = clock.addingTimeInterval(300)
    await probe.reply(a.identity, .failure(.expired)); await probe.reply(b.identity, .success(normal))
    monitor.refresh()
    try await waitForUsage { !monitor.refreshing }
    try requireUsage(monitor.states[a.identity]?.value == normal && monitor.states[a.identity]?.failure == .expired &&
        monitor.states[b.identity]?.value == normal, "failed account retains old value; others update")
    await probe.reply(a.identity, .success(swapped))
    monitor.refresh(force: true)
    try await waitForUsage { !monitor.refreshing }
    try requireUsage(monitor.states[a.identity]?.failure == .expired, "manual refresh respects per-account backoff")
    let renewed = try usageAuth("SIMULATED-a", revision: "renewed")
    loaded = try UsageAccounts(book: book, current: renewed.data)
    monitor.refresh(force: true)
    try await waitForUsage { !monitor.refreshing }
    try requireUsage(monitor.states[a.identity]?.value == swapped && monitor.states[a.identity]?.failure == nil, "newly saved token can recover immediately")
    await probe.reply(a.identity, .failure(.throttled(900)))
    monitor.refresh(force: true)
    try await waitForUsage { !monitor.refreshing }
    try requireUsage(monitor.states[a.identity]?.retryAt == clock.addingTimeInterval(900), "server retry-after extends the normal refresh interval")
    await probe.reply(a.identity, .success(normal))
    let beforeThrottleRetry = await probe.count()
    clock = clock.addingTimeInterval(899)
    monitor.refresh(force: true)
    try await waitForUsage { !monitor.refreshing }
    let duringThrottle = await probe.count()
    try requireUsage(duringThrottle == beforeThrottleRetry + 1 && monitor.states[a.identity]?.failure == .throttled(900), "manual refresh cannot bypass throttling; other account still refreshes")
    clock = clock.addingTimeInterval(1)
    monitor.refresh(force: true)
    try await waitForUsage { !monitor.refreshing }
    try requireUsage(monitor.states[a.identity]?.value == normal && monitor.states[a.identity]?.failure == nil, "retry resumes once server delay expires")
    monitor.pause()
    monitor.refresh(force: true)
    try requireUsage(!monitor.refreshing, "switch transaction pauses refresh")

    // Deliberately ignore cancellation in this fake transport: the old response still
    // must not overwrite the new generation after a switch completes.
    let gate = UsageGate()
    var generationLoad = try UsageAccounts(book: book, current: a.data)
    var loads = 0
    let switching = UsageMonitor(load: {
        loads += 1
        return generationLoad
    }, fetch: { auth in
        if auth.identity == a.identity { return await gate.fetch() }
        return swapped
    })
    var receivedPartialResult = false
    switching.onChange = {
        if switching.refreshing && switching.states[b.identity]?.value == swapped
            && switching.states[a.identity]?.value == nil {
            receivedPartialResult = true
        }
    }
    switching.refresh()
    try await waitForUsage { await gate.didStart() }
    try await waitForUsage { receivedPartialResult }
    try requireUsage(switching.refreshing, "completed accounts notify the open menu while another account is pending")
    switching.onChange = nil
    switching.pause()
    var onlyB = AccountBook(); onlyB.remember(b, label: "B")
    generationLoad = try UsageAccounts(book: onlyB, current: b.data)
    switching.resume()
    try await waitForUsage { !switching.refreshing }
    await gate.finish(normal)
    for _ in 0..<20 { await Task.yield() }
    try requireUsage(loads == 2 && switching.currentIdentity == b.identity && switching.states[a.identity] == nil &&
        switching.states[b.identity]?.value == swapped, "late pre-switch results discarded")
    switching.pause()

    var many = AccountBook()
    for index in 0..<7 {
        let auth = try usageAuth("SIMULATED-many-\(index)")
        many.remember(auth)
        await probe.reply(auth.identity, .success(normal))
    }
    let manyLoaded = try UsageAccounts(book: many, current: nil)
    let bounded = UsageMonitor(load: { manyLoaded }, fetch: { try await probe.fetch($0) })
    bounded.refresh()
    try await waitForUsage { !bounded.refreshing }
    let peak = await probe.peakCount()
    try requireUsage(peak <= 3 && bounded.states.count == 7, "bounded concurrency completes all accounts")
    bounded.pause()

    let locked = UsageMonitor(load: { throw SwitchError("SIMULATED locked keychain") }, fetch: { _ in
        throw SwitchError("must not fetch when loading fails")
    })
    locked.refresh()
    try await waitForUsage { !locked.refreshing }
    try requireUsage(locked.loadError != nil && locked.accounts.isEmpty, "keychain failure does not query cached credentials")
    locked.pause()
    print("Usage tests passed (synthetic accounts, mocked transport, no network).")
}
