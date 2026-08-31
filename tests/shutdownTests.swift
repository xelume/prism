import Foundation
import Darwin

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SwitchError("Shutdown test failed: " + message) }
}

@MainActor
private func expectFailure(_ action: () async throws -> Void) async throws {
    do { try await action() } catch { return }
    throw SwitchError("Shutdown test expected a failure")
}

private func mock(_ pid: Int32, parent: Int32 = 1, name: String = "codex", start: UInt64 = 100) -> ProcessEntry {
    ProcessEntry(pid: pid, executable: "/mock/" + name, parentPID: parent,
                 startedSeconds: start, startedMicroseconds: UInt64(pid))
}

@MainActor
private final class VirtualDesktop {
    let root = mock(10, name: "ChatGPT")
    var processes: [ProcessEntry]
    var seconds: TimeInterval = 0
    var signals: [(ProcessEntry, ShutdownSignal)] = []
    var confirmations: [[ProcessEntry]] = []
    var quitCalled = false
    var allowForce = false
    var ignoreTerminate = false
    var onQuit: ((VirtualDesktop) -> Void)?
    var onTick: ((VirtualDesktop) -> Void)?
    var onConfirm: ((VirtualDesktop) -> Void)?

    init(_ other: [ProcessEntry] = []) { processes = [root] + other }

    func remove(_ pid: Int32) {
        processes.removeAll { $0.pid == pid }
        for index in processes.indices where processes[index].parentPID == pid {
            processes[index].parentPID = 1
        }
    }

    var operations: ShutdownOperations {
        ShutdownOperations(read: { self.processes }, requestQuit: {
            self.quitCalled = true
            if let onQuit = self.onQuit { onQuit(self) } else { self.remove(self.root.pid) }
        }, signal: { entry, signal in
            self.signals.append((entry, signal))
            if signal == .kill || !self.ignoreTerminate { self.remove(entry.pid) }
        }, confirmForce: { entries in
            self.confirmations.append(entries)
            self.onConfirm?(self)
            return self.allowForce
        }, now: { self.seconds }, pause: {
            self.seconds += 1
            self.onTick?(self)
        })
    }
}

@MainActor
func runShutdownTests() async throws {
    // Exits after the old 3s timeout, without unnecessary process signals.
    let natural = VirtualDesktop([mock(11, parent: 10)])
    natural.onTick = { if $0.seconds == 6 { $0.remove(11) } }
    try await ClientShutdown().quit(roots: [natural.root], operations: natural.operations)
    try expect(natural.seconds == 6 && natural.signals.isEmpty && natural.confirmations.isEmpty,
               "slow normal cleanup has adequate grace")

    let graceful = VirtualDesktop([mock(11, parent: 10)])
    try await ClientShutdown().quit(roots: [graceful.root], operations: graceful.operations)
    try expect(graceful.seconds == 10 && graceful.signals.count == 1 && graceful.signals[0].1 == .terminate,
               "reparented helper receives TERM only after grace")

    // Shared executable names do not imply ownership. An independent CLI remains a blocker.
    let independent = VirtualDesktop([mock(11, parent: 10), mock(12, parent: 900)])
    independent.ignoreTerminate = true
    independent.allowForce = true
    try await expectFailure {
        try await ClientShutdown().quit(roots: [independent.root], operations: independent.operations)
    }
    try expect(independent.signals.map { $0.0.pid } == [11, 11], "never signal independent CLI")
    try expect(independent.confirmations[0].map(\.pid) == [11], "force dialog excludes independent CLI")
    try expect(independent.processes.map(\.pid) == [12], "independent process remains alive")

    let canceled = VirtualDesktop([mock(11, parent: 10)])
    canceled.onQuit = { _ in } // Official quit request was canceled or hung.
    try await expectFailure {
        try await ClientShutdown().quit(roots: [canceled.root], operations: canceled.operations)
    }
    try expect(canceled.seconds == 25 && canceled.signals.isEmpty && canceled.confirmations.count == 1,
               "canceled main quit requires explicit confirmation before any signal")

    let forceMain = VirtualDesktop([mock(11, parent: 10)])
    forceMain.onQuit = { _ in }
    forceMain.allowForce = true
    try await ClientShutdown().quit(roots: [forceMain.root], operations: forceMain.operations)
    try expect(forceMain.signals.count == 2 && forceMain.signals.allSatisfy { $0.1 == .kill },
               "approved main timeout ends exactly reviewed root and helper")

    // Ownership remains after cancellation so a retry can clean the now-orphaned helper.
    let retried = VirtualDesktop([mock(11, parent: 10)])
    retried.ignoreTerminate = true
    let retryController = ClientShutdown()
    var credentialsWouldChange = false
    try await expectFailure {
        try await retryController.quit(roots: [retried.root], operations: retried.operations)
        credentialsWouldChange = true
    }
    try expect(!credentialsWouldChange && !retried.signals.contains { $0.1 == .kill }, "cancel preserves auth gate")
    retried.allowForce = true
    try await retryController.quit(roots: [], operations: retried.operations)
    try expect(retried.processes.isEmpty, "retry retains proven ownership without a live main app")

    let reused = VirtualDesktop([mock(11, parent: 10)])
    reused.ignoreTerminate = true
    reused.allowForce = true
    reused.onConfirm = { $0.processes = [mock(11, start: 101)] }
    try await expectFailure {
        try await ClientShutdown().quit(roots: [reused.root], operations: reused.operations)
    }
    try expect(!reused.signals.contains { $0.1 == .kill }, "PID reuse during dialog never inherits kill approval")

    let spawnedDuringDialog = VirtualDesktop([mock(11, parent: 10)])
    spawnedDuringDialog.onQuit = { _ in }
    spawnedDuringDialog.allowForce = true
    spawnedDuringDialog.onConfirm = { $0.processes.append(mock(13, parent: 10, start: 120)) }
    try await expectFailure {
        try await ClientShutdown().quit(roots: [spawnedDuringDialog.root], operations: spawnedDuringDialog.operations)
    }
    try expect(!spawnedDuringDialog.signals.contains { $0.0.pid == 13 }, "new process not in dialog is not force-killed")

    let disappearing = VirtualDesktop([mock(11, parent: 10)])
    disappearing.ignoreTerminate = true
    disappearing.allowForce = true
    disappearing.onConfirm = { $0.remove(11) }
    try await ClientShutdown().quit(roots: [disappearing.root], operations: disappearing.operations)
    try expect(!disappearing.signals.contains { $0.1 == .kill }, "skip processes that exited during confirmation")

    let lateChild = VirtualDesktop()
    lateChild.onQuit = { _ in }
    lateChild.onTick = {
        if $0.seconds == 2 { $0.processes.append(mock(11, parent: 10)) }
        if $0.seconds == 4 { $0.remove(10) }
    }
    try await ClientShutdown().quit(roots: [lateChild.root], operations: lateChild.operations)
    try expect(lateChild.signals.map { $0.0.pid } == [11], "capture descendants born during normal quit")

    let orphan = VirtualDesktop()
    orphan.processes = [mock(11)]
    try await expectFailure { try await ClientShutdown().quit(roots: [], operations: orphan.operations) }
    try expect(orphan.signals.isEmpty && orphan.confirmations.isEmpty, "unproven preexisting orphans are never killed")

    let exitedBeforeRequest = VirtualDesktop([mock(11, parent: 10)])
    let captured = exitedBeforeRequest.processes
    exitedBeforeRequest.remove(10)
    try await ClientShutdown().quit(roots: [exitedBeforeRequest.root], initialSnapshot: captured,
                                    operations: exitedBeforeRequest.operations)
    try expect(exitedBeforeRequest.signals.map { $0.0.pid } == [11], "retain initial capture if main exits before quit request")

    var cached = mock(11, parent: 10)
    cached.hasVerifiedExecutablePath = false
    let pathUnavailable = VirtualDesktop([cached])
    pathUnavailable.allowForce = true
    try await expectFailure {
        try await ClientShutdown().quit(roots: [pathUnavailable.root], operations: pathUnavailable.operations)
    }
    try expect(pathUnavailable.signals.isEmpty && pathUnavailable.confirmations.isEmpty,
               "cached executable names are classification-only, never signal authority")

    var tree = ClientProcessTree()
    let root = mock(10, name: "ChatGPT")
    let shell = mock(20, parent: 10, name: "sh")
    let child = mock(30, parent: 20)
    let server = mock(40, parent: 10, name: "node")
    tree.observe([child, shell, server, root], roots: [root])
    try expect(Set(tree.residuals(in: [child, shell, server, root]).map(\.pid)) == [10, 30],
               "trace through shell intermediates without terminating unrelated task executables")
    var recycledParent = root
    recycledParent.startedMicroseconds += 1
    let unknownChild = mock(50, parent: 10)
    tree.observe([recycledParent, unknownChild, child])
    try expect(!tree.owns(recycledParent) && !tree.owns(unknownChild) && tree.owns(child),
               "microsecond identity prevents recycled parent from acquiring new descendants")
    var changedExecutable = child
    changedExecutable = ProcessEntry(pid: child.pid, executable: "/other/codex", parentPID: 1,
                                      startedSeconds: child.startedSeconds, startedMicroseconds: child.startedMicroseconds)
    tree.observe([changedExecutable])
    try expect(!tree.owns(changedExecutable), "changed executable does not inherit signal authorization")
    var zombie = mock(11)
    zombie.isZombie = true
    try tree.requireStopped([zombie])

    let unreadable = VirtualDesktop()
    var unreadableOperations = unreadable.operations
    unreadableOperations.read = { throw SwitchError("simulated enumeration failure") }
    try await expectFailure { try await ClientShutdown().quit(roots: [unreadable.root], operations: unreadableOperations) }
    try expect(!unreadable.quitCalled && unreadable.signals.isEmpty, "enumeration failure is fail-closed")
    let denied = VirtualDesktop([mock(11, parent: 10)])
    var deniedOperations = denied.operations
    deniedOperations.signal = { _, _ in throw SwitchError("simulated signal denied") }
    try await expectFailure { try await ClientShutdown().quit(roots: [denied.root], operations: deniedOperations) }
    try expect(denied.confirmations.isEmpty, "signal permission failure does not escalate automatically")
    print("PASS: slow exit, owned residual cleanup, independent CLI protection, force/cancel, retry, PID reuse, new children, zombies, and inspection failures")
}

func runNativeProcessTests() throws {
    let helper = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("codex-shutdown-fixture")
    let child = Process()
    child.executableURL = helper
    let ready = Pipe()
    child.standardOutput = ready
    child.standardError = FileHandle.nullDevice
    try child.run()
    defer {
        if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
    }
    guard try ready.fileHandleForReading.read(upToCount: 1) == Data([1]),
          let entry = try NativeProcesses.entry(pid: child.processIdentifier) else {
        throw SwitchError("Native test fixture did not become ready")
    }
    try expect(entry.parentPID == getpid() && entry.startedSeconds > 0 && entry.isCodex,
               "kernel adapter reads own disposable helper identity")
    let snapshot = try NativeProcesses.snapshot()
    try expect(snapshot.contains(where: { $0.isSameInstance(as: entry) }),
               "current-user inventory contains the disposable helper")
    var wrongInstance = entry
    wrongInstance.startedMicroseconds += 1
    try NativeProcesses.signal(wrongInstance, .kill)
    try expect(child.isRunning, "native adapter refuses stale process identity")
    try NativeProcesses.signal(entry, .terminate)
    Thread.sleep(forTimeInterval: 0.05)
    try expect(child.isRunning, "fixture intentionally ignores TERM")
    try NativeProcesses.signal(entry, .kill)
    child.waitUntilExit()
    try expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL,
               "native adapter terminates only its disposable test helper")
    print("PASS: real kernel metadata and TERM/KILL against a disposable test child only")
}
