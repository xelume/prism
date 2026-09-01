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
        // Chromium's crash reporter can remain orphaned after ChatGPT exits. It only
        // writes crash diagnostics and does not consume the shared authentication file.
        if name == "browser_crashpad_handler" { return false }
        return name == "codex" || name.hasPrefix("codex-") || name == "chatgpt"
            || name.hasPrefix("chatgpt helper") || executable.contains("/ChatGPT.app/")
    }

    func isSameInstance(as other: ProcessEntry) -> Bool {
        identity == other.identity && executable == other.executable
    }

    var summary: String {
        "\(URL(fileURLWithPath: executable).lastPathComponent)（PID \(pid)，父进程 \(parentPID)）"
    }

    // Path hints explain blockers; they never establish ownership or signal authority.
    var independentProcessGuidance: String {
        let components = URL(fileURLWithPath: executable).pathComponents
        if components.indices.contains(where: {
            components[$0] == ".vscode" && $0 + 3 < components.count
                && components[$0 + 1] == "extensions"
                && components[$0 + 2].hasPrefix("openai.chatgpt-")
        }) {
            return "来自 VS Code 的 Codex：请保存工作并完全退出 VS Code；只关闭 Codex 面板可能无法结束后台任务"
        }
        return "来自终端或 IDE 的 Codex：请结束相关任务和后台服务"
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

    func requireIndependentProcessesStopped(_ snapshot: [ProcessEntry]) throws {
        try requireStopped(snapshot.filter { !owns($0) })
    }

    func requireStopped(_ snapshot: [ProcessEntry]) throws {
        let remaining = blockers(in: snapshot)
        guard remaining.isEmpty else {
            let details = remaining.map {
                "• \($0.summary) — \(owns($0) ? "ChatGPT 尚未完全退出" : $0.independentProcessGuidance)"
            }.joined(separator: "\n")
            throw SwitchError("请先结束以下 Codex 任务：\n\n\(details)")
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
        try tree.requireIndependentProcessesStopped(initial)
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
            throw SwitchError("已取消强制结束，账号没有切换。ChatGPT 可能已退出部分进程，你可以手动重新打开。")
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
