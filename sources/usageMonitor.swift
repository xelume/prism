import Foundation

struct UsageAccounts {
    let accounts: [SavedAccount]
    let savedIdentities: Set<String>
    let currentIdentity: String?

    init(book: AccountBook, current: Data?) throws {
        try book.validate()
        savedIdentities = Set(book.accounts.map(\.identity))
        var currentBook = book
        if let current {
            let snapshot = try AuthSnapshot(current)
            currentIdentity = snapshot.identity
            // Use the official client's latest token in memory, never overwrite the vault
            // from a background query (the switching transaction owns persistence).
            currentBook.remember(snapshot, label: savedIdentities.contains(snapshot.identity) ? nil : "当前账号（尚未保存）")
        } else { currentIdentity = nil }
        accounts = currentBook.accounts
    }
}

struct UsageState {
    var value: AccountUsage?
    var updatedAt: Date?
    var failure: UsageFailure?
    var retryAt: Date?
    var nextRefreshAt: Date?
    var consecutiveFailures = 0
    var resetConfirmationAttempts = 0
}

private struct UsageOutcome {
    let identity: String
    let value: AccountUsage?
    let failure: UsageFailure?
}

private enum UsageRefreshTrigger {
    case scheduled, menu, force
}

@MainActor
final class UsageMonitor {
    private let load: () async throws -> UsageAccounts
    private let fetch: @Sendable (AuthSnapshot) async throws -> AccountUsage
    private let now: () -> Date
    private let statusBarUsageEnabled: () -> Bool
    private let jitter: () -> TimeInterval
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var nextScheduledCheck = Date.distantPast
    private var paused = false
    private(set) var accounts: [SavedAccount] = []
    private(set) var savedIdentities: Set<String> = []
    private(set) var currentIdentity: String?
    private(set) var states: [String: UsageState] = [:]
    private(set) var loadError: String?
    private(set) var refreshing = false
    var onChange: (() -> Void)?

    init(load: @escaping () async throws -> UsageAccounts,
         fetch: @escaping @Sendable (AuthSnapshot) async throws -> AccountUsage,
         now: @escaping () -> Date = Date.init,
         statusBarUsageEnabled: @escaping () -> Bool = { false },
         jitter: @escaping () -> TimeInterval = { Double.random(in: -10...10) }) {
        self.load = load
        self.fetch = fetch
        self.now = now
        self.statusBarUsageEnabled = statusBarUsageEnabled
        self.jitter = jitter
    }

    func refresh(force: Bool = false) {
        start(force ? .force : .scheduled)
    }

    func refreshOnMenuOpen() { start(.menu) }

    func statusBarUsageModeDidChange() {
        guard let currentIdentity, var state = states[currentIdentity], let updatedAt = state.updatedAt else {
            nextScheduledCheck = Date.distantPast
            refresh()
            return
        }
        state.nextRefreshAt = max(state.retryAt ?? Date.distantPast,
            nextSuccessRefresh(for: state.value, updatedAt: updatedAt,
                               current: true, confirmationAttempts: state.resetConfirmationAttempts))
        states[currentIdentity] = state
        updateNextScheduledCheck()
        refresh()
    }

    private func start(_ trigger: UsageRefreshTrigger) {
        guard !paused, task == nil,
              trigger != .scheduled || now() >= nextScheduledCheck,
              trigger != .menu || accounts.isEmpty || accounts.contains(where: { account in
                  (states[account.identity]?.retryAt ?? Date.distantPast) <= now()
                      && shouldRefresh(account.identity, trigger: .menu)
              }) else { return }
        let revision = UUID()
        generation = revision
        refreshing = true
        onChange?()
        task = Task { [weak self] in await self?.run(revision: revision, trigger: trigger) }
    }

    func pause() {
        paused = true
        generation = UUID()
        task?.cancel()
        task = nil
        refreshing = false
    }

    func resume() { paused = false; refresh(force: true) }

    private func run(revision: UUID, trigger: UsageRefreshTrigger) async {
        defer {
            if generation == revision {
                task = nil
                refreshing = false
                updateNextScheduledCheck()
                onChange?()
            }
        }
        do {
            let loaded = try await load()
            guard generation == revision, !Task.isCancelled else { return }
            let oldAuth = Dictionary(uniqueKeysWithValues: accounts.map { ($0.identity, $0.auth) })
            accounts = loaded.accounts
            currentIdentity = loaded.currentIdentity
            savedIdentities = loaded.savedIdentities
            loadError = nil
            let identities = Set(accounts.map(\.identity))
            states = states.filter { identities.contains($0.key) }
            var pending: [AuthSnapshot] = []
            for account in accounts {
                // A newly saved or refreshed login can immediately retry a previously
                // expired token; manual refresh still respects server Retry-After.
                let authChanged = oldAuth[account.identity] != account.auth
                if authChanged, states[account.identity]?.failure == .expired {
                    states[account.identity]?.retryAt = nil
                }
                if let retry = states[account.identity]?.retryAt, retry > now() { continue }
                guard authChanged || shouldRefresh(account.identity, trigger: trigger) else { continue }
                pending.append(try AuthSnapshot(account.auth))
            }
            onChange?()
            let fetch = self.fetch
            await withTaskGroup(of: UsageOutcome.self) { group in
                var iterator = pending.makeIterator()
                func enqueue(_ auth: AuthSnapshot) {
                    group.addTask {
                        do { return UsageOutcome(identity: auth.identity, value: try await fetch(auth), failure: nil) }
                        catch { return UsageOutcome(identity: auth.identity, value: nil,
                            failure: (error as? UsageFailure) ?? .unavailable) }
                    }
                }
                for _ in 0..<3 { if let auth = iterator.next() { enqueue(auth) } }
                for await result in group {
                    guard generation == revision, !Task.isCancelled else { group.cancelAll(); return }
                    var state = states[result.identity] ?? UsageState()
                    if let value = result.value {
                        let completedAt = now()
                        let elapsedReset = elapsedResetTime(value, at: completedAt)
                        let previousElapsedReset = state.value.flatMap { elapsedResetTime($0, at: completedAt) }
                        let attempts = elapsedReset != nil && elapsedReset == previousElapsedReset
                            ? state.resetConfirmationAttempts + 1 : (elapsedReset == nil ? 0 : 1)
                        state = UsageState(value: value, updatedAt: completedAt, failure: nil, retryAt: nil,
                            nextRefreshAt: nextSuccessRefresh(for: value, updatedAt: completedAt,
                                current: result.identity == currentIdentity, confirmationAttempts: attempts),
                            consecutiveFailures: 0, resetConfirmationAttempts: attempts)
                    } else {
                        state.failure = result.failure
                        state.consecutiveFailures += 1
                        let delay: TimeInterval
                        if case .throttled(let retryAfter) = result.failure {
                            delay = max(300, min(3600, retryAfter))
                        } else {
                            let delays: [TimeInterval] = [300, 600, 1200, 1800]
                            delay = delays[min(state.consecutiveFailures - 1, delays.count - 1)]
                        }
                        state.retryAt = now().addingTimeInterval(delay)
                        state.nextRefreshAt = state.retryAt
                    }
                    states[result.identity] = state
                    onChange?()
                    if let auth = iterator.next() { enqueue(auth) }
                }
            }
        } catch {
            guard generation == revision, !Task.isCancelled else { return }
            currentIdentity = nil
            loadError = (error as? SwitchError)?.message ?? "无法加载账号。请确认已经登录，并允许 Prism 访问钥匙串。"
            // Do not keep background credentials alive when the keychain becomes locked.
            accounts = []
            savedIdentities = []
        }
    }

    private func shouldRefresh(_ identity: String, trigger: UsageRefreshTrigger) -> Bool {
        guard let state = states[identity], let updatedAt = state.updatedAt else { return true }
        switch trigger {
        case .force: return true
        case .scheduled: return now() >= (state.nextRefreshAt ?? Date.distantPast)
        case .menu:
            let threshold: TimeInterval = identity == currentIdentity ? 60 : 300
            return now().timeIntervalSince(updatedAt) >= threshold
        }
    }

    private func nextSuccessRefresh(for value: AccountUsage?, updatedAt: Date, current: Bool,
                                    confirmationAttempts: Int) -> Date {
        if elapsedResetTime(value, at: updatedAt) != nil, confirmationAttempts < 3 {
            return updatedAt.addingTimeInterval(60)
        }
        let interval: TimeInterval = current ? (statusBarUsageEnabled() ? 60 : 180) : 900
        let periodic = updatedAt.addingTimeInterval(max(15, interval + jitter()))
        let resetConfirmation = futureResetTime(value, after: updatedAt)
            .map { Date(timeIntervalSince1970: $0 + 15) }
        return min(periodic, resetConfirmation ?? Date.distantFuture)
    }

    private func futureResetTime(_ value: AccountUsage?, after date: Date) -> TimeInterval? {
        [value?.fiveHour?.resetsAt, value?.week?.resetsAt].compactMap { $0 }
            .filter { $0 > date.timeIntervalSince1970 }.min()
    }

    private func elapsedResetTime(_ value: AccountUsage?, at date: Date) -> TimeInterval? {
        [value?.fiveHour?.resetsAt, value?.week?.resetsAt].compactMap { $0 }
            .filter { $0 <= date.timeIntervalSince1970 }.max()
    }

    private func updateNextScheduledCheck() {
        nextScheduledCheck = states.values.compactMap(\.nextRefreshAt).min() ?? now().addingTimeInterval(900)
    }
}
