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
            currentBook.remember(snapshot, label: savedIdentities.contains(snapshot.identity) ? nil : "未保存账号")
        } else { currentIdentity = nil }
        accounts = currentBook.accounts
    }
}

struct UsageState {
    var value: AccountUsage?
    var updatedAt: Date?
    var failure: UsageFailure?
    var retryAt: Date?
}

private struct UsageOutcome {
    let identity: String
    let value: AccountUsage?
    let failure: UsageFailure?
}

@MainActor
final class UsageMonitor {
    private let load: () async throws -> UsageAccounts
    private let fetch: @Sendable (AuthSnapshot) async throws -> AccountUsage
    private let now: () -> Date
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var nextRefresh = Date.distantPast
    private var lastRefreshCompletedAt: Date?
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
         now: @escaping () -> Date = Date.init) {
        self.load = load
        self.fetch = fetch
        self.now = now
    }

    func refresh(force: Bool = false) {
        guard !paused, task == nil, force || now() >= nextRefresh else { return }
        let revision = UUID()
        generation = revision
        refreshing = true
        onChange?()
        task = Task { [weak self] in await self?.run(revision: revision) }
    }

    func refreshOnMenuOpen() {
        if let lastRefreshCompletedAt, now().timeIntervalSince(lastRefreshCompletedAt) < 30 { return }
        refresh(force: true)
    }

    func pause() {
        paused = true
        generation = UUID()
        task?.cancel()
        task = nil
        refreshing = false
    }

    func resume() { paused = false; refresh(force: true) }

    private func run(revision: UUID) async {
        defer {
            if generation == revision {
                task = nil
                refreshing = false
                let completedAt = now()
                lastRefreshCompletedAt = completedAt
                nextRefresh = completedAt.addingTimeInterval(300)
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
                if oldAuth[account.identity] != account.auth,
                   states[account.identity]?.failure == .expired { states[account.identity]?.retryAt = nil }
                if let retry = states[account.identity]?.retryAt, retry > now() { continue }
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
                        state = UsageState(value: value, updatedAt: now(), failure: nil, retryAt: nil)
                    } else {
                        state.failure = result.failure
                        state.retryAt = now().addingTimeInterval(result.failure?.retryDelay ?? 300)
                    }
                    states[result.identity] = state
                    onChange?()
                    if let auth = iterator.next() { enqueue(auth) }
                }
            }
        } catch {
            guard generation == revision, !Task.isCancelled else { return }
            currentIdentity = nil
            loadError = (error as? SwitchError)?.message ?? "无法加载账号，请检查登录状态和钥匙串权限。"
            // Do not keep background credentials alive when the keychain becomes locked.
            accounts = []
            savedIdentities = []
        }
    }
}
