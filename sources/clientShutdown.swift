import Foundation

struct ProcessIdentity: Hashable {
    let pid: Int32
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
}

struct ProcessEntry {
    let pid: Int32
    let executable: String
    var parentPID: Int32 = 0
    var startedSeconds: UInt64 = 0
    var startedMicroseconds: UInt64 = 0
    var isZombie = false
    var hasVerifiedExecutablePath = true

    var identity: ProcessIdentity {
        ProcessIdentity(pid: pid, startedSeconds: startedSeconds, startedMicroseconds: startedMicroseconds)
    }

    var isCodex: Bool {
        let name = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        return name == "codex" || name.hasPrefix("codex-") || name == "chatgpt"
            || name.hasPrefix("chatgpt helper") || executable.contains("/ChatGPT.app/")
    }

    func isSameInstance(as other: ProcessEntry) -> Bool {
        identity == other.identity && executable == other.executable
    }

    var summary: String {
        "\(URL(fileURLWithPath: executable).lastPathComponent)（PID \(pid)，父进程 \(parentPID)）"
    }
}

// Ownership is observed before quit and retained across reparenting and canceled retries.
// A matching name/path alone never authorizes signaling an independent process.
struct ClientProcessTree {
    private var known: [ProcessIdentity: ProcessEntry] = [:]

    mutating func observe(_ snapshot: [ProcessEntry], roots: [ProcessEntry] = []) {
        let live = snapshot.filter { !$0.isZombie }
        var next: [ProcessIdentity: ProcessEntry] = [:]
        for entry in live {
            if let old = known[entry.identity], entry.isSameInstance(as: old) {
                next[entry.identity] = entry
            }
            if roots.contains(where: { entry.isSameInstance(as: $0) }) {
                next[entry.identity] = entry
            }
        }
        var changed = true
        while changed {
            changed = false
            let parents = Set(next.values.map(\.pid))
            for entry in live where next[entry.identity] == nil && parents.contains(entry.parentPID) {
                next[entry.identity] = entry
                changed = true
            }
        }
        known = next
    }

    func owns(_ entry: ProcessEntry) -> Bool {
        guard let original = known[entry.identity] else { return false }
        return !entry.isZombie && entry.isSameInstance(as: original)
    }

    func residuals(in snapshot: [ProcessEntry]) -> [ProcessEntry] {
        snapshot.filter { $0.isCodex && owns($0) }
    }

    func blockers(in snapshot: [ProcessEntry]) -> [ProcessEntry] {
        snapshot.filter { $0.isCodex && !$0.isZombie }
    }

    func requireStopped(_ snapshot: [ProcessEntry]) throws {
        let remaining = blockers(in: snapshot)
        guard remaining.isEmpty else {
            let details = remaining.map {
                "• \($0.summary) — \(owns($0) ? "客户端残留" : "独立进程或归属未确认")"
            }.joined(separator: "\n")
            throw SwitchError("仍有进程可能使用当前认证，切换已停止：\n\n\(details)\n\n请结束独立终端／IDE 任务或其后台服务后重试。无法确认归属的进程不会自动结束。")
        }
    }
}

enum ShutdownSignal { case terminate, kill }

// Explicit platform boundary: tests advance a virtual clock and record signals;
// production observes the kernel and uses normal AppKit quit before any signals.
@MainActor
struct ShutdownOperations {
    var read: () throws -> [ProcessEntry]
    var requestQuit: () throws -> Void
    var signal: (ProcessEntry, ShutdownSignal) throws -> Void
    var confirmForce: ([ProcessEntry]) -> Bool
    var now: () -> TimeInterval
    var pause: () async throws -> Void
}

@MainActor
final class ClientShutdown {
    private var tree = ClientProcessTree()

    func requireStopped(_ snapshot: [ProcessEntry]) throws {
        tree.observe(snapshot)
        try tree.requireStopped(snapshot)
    }

    func quit(roots: [ProcessEntry], initialSnapshot: [ProcessEntry]? = nil,
              operations: ShutdownOperations) async throws {
        let initial: [ProcessEntry]
        if let initialSnapshot { initial = initialSnapshot } else { initial = try operations.read() }
        tree.observe(initial, roots: roots)
        try operations.requestQuit()
        let afterQuit = try await wait(seconds: 25, operations: operations) { snapshot in
            !snapshot.contains { entry in
                !entry.isZombie && roots.contains(where: { entry.isSameInstance(as: $0) })
            }
        }
        let mainStillRunning = afterQuit.contains { entry in
            !entry.isZombie && roots.contains(where: { entry.isSameInstance(as: $0) })
        }
        if mainStillRunning {
            // A canceled official quit dialog must never silently become SIGTERM.
            try await forceAfterConfirmation(snapshot: afterQuit, operations: operations)
        } else {
            let natural = try await wait(seconds: 10, operations: operations) { self.tree.residuals(in: $0).isEmpty }
            for entry in tree.residuals(in: natural) where entry.hasVerifiedExecutablePath {
                try operations.signal(entry, .terminate)
            }
            let graceful = try await wait(seconds: 5, operations: operations) { self.tree.residuals(in: $0).isEmpty }
            if !tree.residuals(in: graceful).isEmpty {
                try await forceAfterConfirmation(snapshot: graceful, operations: operations)
            }
        }
        try requireStopped(operations.read())
    }

    private func forceAfterConfirmation(snapshot: [ProcessEntry], operations: ShutdownOperations) async throws {
        let candidates = tree.residuals(in: snapshot).filter(\.hasVerifiedExecutablePath)
        guard !candidates.isEmpty else { return }
        guard operations.confirmForce(candidates) else {
            throw SwitchError("已取消强制结束，未切换账号。客户端可能已部分退出，可手动重新打开。")
        }
        // Re-read after the modal dialog: only the exact reviewed instances are approved.
        let fresh = try operations.read()
        tree.observe(fresh)
        for entry in tree.residuals(in: fresh) where entry.hasVerifiedExecutablePath
            && candidates.contains(where: { entry.isSameInstance(as: $0) }) {
            try operations.signal(entry, .kill)
        }
        _ = try await wait(seconds: 5, operations: operations) { self.tree.residuals(in: $0).isEmpty }
    }

    private func wait(seconds: TimeInterval, operations: ShutdownOperations,
                      until finished: ([ProcessEntry]) -> Bool) async throws -> [ProcessEntry] {
        let deadline = operations.now() + seconds
        while true {
            let snapshot = try operations.read()
            tree.observe(snapshot)
            if finished(snapshot) || operations.now() >= deadline { return snapshot }
            try await operations.pause()
        }
    }
}
