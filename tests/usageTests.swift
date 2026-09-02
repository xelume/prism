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
    try requireUsage(StatusBarUsageTitle.make(mode: .off, usage: normal) == nil,
                     "status bar usage defaults to hidden output")
    try requireUsage(StatusBarUsageTitle.make(mode: .brief, usage: normal) == "5h 79%",
                     "brief status title uses the shortest available window")
    try requireUsage(StatusBarUsageTitle.make(mode: .all, usage: normal) == "5h 79% · 7d 0%",
                     "all status title includes every available window")
    let partialUsage = AccountUsage(fiveHour: normal.fiveHour, week: nil)
    try requireUsage(StatusBarUsageTitle.make(mode: .all, usage: partialUsage) == "5h 79%",
                     "status title omits unavailable windows")
    try requireUsage(StatusBarUsageMode.brief.menuTitle == "简略" &&
                     StatusBarUsageMode.all.menuTitle == "全部",
                     "status bar usage menu exposes brief and all modes")

    let menuNow = Date(timeIntervalSince1970: 1_999_993_700)
    let utc = TimeZone(secondsFromGMT: 0)!
    try requireUsage(UsageMenuTitle.make(kind: .fiveHour, window: normal.fiveHour!,
                                         now: menuNow, timeZone: utc) == "5h 79% · 1h45m",
                     "five-hour menu title uses compact countdown")
    try requireUsage(UsageMenuTitle.make(kind: .week, window: normal.week!,
                                         now: menuNow, timeZone: utc) == "7d 0% · 5/25 02:13",
                     "weekly menu title uses compact reset date")

    let monthly = try decodeUsage("""
    {"rate_limit":{"primary_window":{"used_percent":12.5,"limit_window_seconds":2592000,"reset_at":2000600000}}}
    """)
    try requireUsage(monthly.month?.remainingPercent == 87 && monthly.fiveHour == nil && monthly.week == nil,
                     "28-to-31-day windows map to monthly usage")
    try requireUsage(UsageMenuTitle.make(kind: .month, window: monthly.month!,
                                         now: menuNow, timeZone: utc) == "1mo 87% · 5/25 02:13",
                     "monthly menu title uses compact reset date")
    try requireUsage(StatusBarUsageTitle.make(mode: .brief, usage: monthly) == "1mo 87%",
                     "brief status falls back to the shortest available window")
    let allWindows = AccountUsage(fiveHour: normal.fiveHour, week: normal.week, month: monthly.month)
    try requireUsage(StatusBarUsageTitle.make(mode: .all, usage: allWindows) ==
                     "5h 79% · 7d 0% · 1mo 87%",
                     "all status includes monthly usage")

    let defaultsName = "StatusBarUsageTests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: defaultsName)!
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let preference = StatusBarUsagePreference(defaults: defaults)
    try requireUsage(preference.mode == .off, "status bar usage is off by default")
    preference.mode = .all
    try requireUsage(preference.mode == .all, "status bar usage preference persists")
    defaults.set("fiveHour", forKey: StatusBarUsagePreference.key)
    try requireUsage(preference.mode == .brief, "legacy single-window preference migrates to brief")
    defaults.set("both", forKey: StatusBarUsagePreference.key)
    try requireUsage(preference.mode == .all, "legacy combined preference migrates to all")
    defaults.set("invalid", forKey: StatusBarUsagePreference.key)
    try requireUsage(preference.mode == .off, "invalid status bar preference falls back to off")
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
    var statusBarUsageEnabled = false
    let probe = UsageProbe()
    await probe.reply(a.identity, .success(normal)); await probe.reply(b.identity, .success(swapped))
    let monitor = UsageMonitor(load: { loaded }, fetch: { try await probe.fetch($0) }, now: { clock },
        statusBarUsageEnabled: { statusBarUsageEnabled }, jitter: { 0 })
    monitor.refreshOnMenuOpen(); monitor.refreshOnMenuOpen()
    try await waitForUsage { !monitor.refreshing }
    let firstCount = await probe.count()
    try requireUsage(firstCount == 2, "no overlapping refresh batches")
    try requireUsage(monitor.states[a.identity]?.value == normal && monitor.states[b.identity]?.value == swapped, "per-account cache isolation")
    monitor.refresh()
    try requireUsage(!monitor.refreshing, "fresh accounts are not polled by the scheduler")
    monitor.refreshOnMenuOpen()
    try requireUsage(!monitor.refreshing, "reopening immediately uses cached usage")
    clock = clock.addingTimeInterval(59)
    monitor.refreshOnMenuOpen()
    try requireUsage(!monitor.refreshing, "current-account menu threshold lasts sixty seconds")
    let cachedCount = await probe.count()
    try requireUsage(cachedCount == firstCount, "repeated opens during cooldown send no requests")
    clock = clock.addingTimeInterval(1)
    monitor.refreshOnMenuOpen()
    monitor.refreshOnMenuOpen()
    try await waitForUsage { !monitor.refreshing }
    let reopenedCount = await probe.count()
    try requireUsage(reopenedCount == firstCount + 1,
        "menu refreshes only the stale current account and coalesces in-flight requests")
    monitor.refreshOnMenuOpen()
    try requireUsage(!monitor.refreshing, "completed menu refresh starts a new cooldown")

    clock = clock.addingTimeInterval(239)
    monitor.refreshOnMenuOpen()
    try await waitForUsage { !monitor.refreshing }
    let beforeBackgroundThresholdCount = await probe.count()
    try requireUsage(beforeBackgroundThresholdCount == reopenedCount + 1,
        "menu refreshes only the stale current account before the background threshold")
    clock = clock.addingTimeInterval(1)
    monitor.refreshOnMenuOpen()
    try await waitForUsage { !monitor.refreshing }
    let fiveMinuteMenuCount = await probe.count()
    try requireUsage(fiveMinuteMenuCount == beforeBackgroundThresholdCount + 1,
        "menu refreshes the background account at five minutes")

    clock = clock.addingTimeInterval(178)
    monitor.refresh()
    try requireUsage(!monitor.refreshing, "hidden status uses a three-minute current-account interval")
    clock = clock.addingTimeInterval(1)
    monitor.refresh()
    try await waitForUsage { !monitor.refreshing }
    let hiddenStatusCount = await probe.count()
    try requireUsage(hiddenStatusCount == fiveMinuteMenuCount + 1,
        "three-minute refresh updates only the current account")

    statusBarUsageEnabled = true
    monitor.statusBarUsageModeDidChange()
    try requireUsage(!monitor.refreshing, "enabling status display keeps a fresh current value")
    clock = clock.addingTimeInterval(59)
    monitor.refresh()
    try requireUsage(!monitor.refreshing, "visible status waits one minute")
    clock = clock.addingTimeInterval(1)
    monitor.refresh()
    try await waitForUsage { !monitor.refreshing }
    let visibleStatusCount = await probe.count()
    try requireUsage(visibleStatusCount == hiddenStatusCount + 1,
        "visible status refreshes the current account every minute")

    await probe.reply(a.identity, .failure(.expired)); await probe.reply(b.identity, .success(normal))
    monitor.refresh(force: true)
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

    await probe.reply(a.identity, .failure(.unavailable))
    for (failureNumber, delay) in [300, 600, 1200, 1800].enumerated() {
        monitor.refresh(force: true)
        try await waitForUsage { !monitor.refreshing }
        try requireUsage(monitor.states[a.identity]?.retryAt == clock.addingTimeInterval(TimeInterval(delay)),
            "ordinary failure backoff step \(failureNumber + 1)")
        if failureNumber == 0 {
            statusBarUsageEnabled = false
            monitor.statusBarUsageModeDidChange()
            try requireUsage(monitor.states[a.identity]?.nextRefreshAt == monitor.states[a.identity]?.retryAt,
                "status display changes cannot bypass account backoff")
            statusBarUsageEnabled = true
            monitor.statusBarUsageModeDidChange()
        }
        clock = clock.addingTimeInterval(TimeInterval(delay))
    }
    await probe.reply(a.identity, .success(normal))
    monitor.refresh(force: true)
    try await waitForUsage { !monitor.refreshing }
    try requireUsage(monitor.states[a.identity]?.consecutiveFailures == 0,
        "successful refresh resets ordinary failure backoff")

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

    let resetProbe = UsageProbe()
    let resetUsage = AccountUsage(
        fiveHour: UsageWindow(usedPercent: 20, seconds: 18_000,
                              resetsAt: clock.timeIntervalSince1970 + 100),
        week: nil)
    await resetProbe.reply(a.identity, .success(resetUsage))
    let resetMonitor = UsageMonitor(load: { try UsageAccounts(book: book, current: a.data) },
        fetch: { try await resetProbe.fetch($0) }, now: { clock }, jitter: { 0 })
    resetMonitor.refresh()
    try await waitForUsage { !resetMonitor.refreshing }
    let resetInitialCount = await resetProbe.count()
    clock = clock.addingTimeInterval(114)
    resetMonitor.refresh()
    try requireUsage(!resetMonitor.refreshing, "reset confirmation waits until fifteen seconds after reset")
    clock = clock.addingTimeInterval(1)
    resetMonitor.refresh()
    try await waitForUsage { !resetMonitor.refreshing }
    let firstResetConfirmationCount = await resetProbe.count()
    try requireUsage(firstResetConfirmationCount == resetInitialCount + 1,
        "first reset confirmation runs fifteen seconds after reset")
    for attempt in 2...3 {
        clock = clock.addingTimeInterval(60)
        resetMonitor.refresh()
        try await waitForUsage { !resetMonitor.refreshing }
        let resetConfirmationCount = await resetProbe.count()
        try requireUsage(resetConfirmationCount == resetInitialCount + attempt,
            "bounded reset confirmation attempt \(attempt)")
    }
    clock = clock.addingTimeInterval(60)
    resetMonitor.refresh()
    try requireUsage(!resetMonitor.refreshing,
        "reset confirmation returns to the normal interval after three attempts")
    resetMonitor.pause()

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
