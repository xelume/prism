import Foundation
import Darwin

enum NativeProcesses {
    static func snapshot() throws -> [ProcessEntry] {
        // Kernel metadata provides microsecond start times; ps PID/name matching alone
        // cannot safely identify an instance after its parent exits or the PID is reused.
        for _ in 0..<3 {
            let bytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
            guard bytes > 0 else { throw SwitchError("无法检查正在运行的 Codex 任务，因此没有切换账号。请稍后再试。") }
            var pids = [Int32](repeating: 0, count: Int(bytes) / MemoryLayout<Int32>.size + 256)
            let capacity = pids.count * MemoryLayout<Int32>.size
            let used = pids.withUnsafeMutableBytes {
                proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32(capacity))
            }
            guard used > 0 else { throw SwitchError("无法检查正在运行的应用，因此没有切换账号。请稍后再试。") }
            if used >= capacity { continue }
            var result: [ProcessEntry] = []
            for pid in pids.prefix(Int(used) / MemoryLayout<Int32>.size) where pid > 0 {
                if let entry = try entry(pid: pid) { result.append(entry) }
            }
            return result.sorted { $0.pid < $1.pid }
        }
        throw SwitchError("正在运行的应用仍在变化，Prism 暂时无法安全切换账号。请稍后再试。")
    }

    static func entry(pid: Int32) throws -> ProcessEntry? {
        guard let before = try info(pid: pid), before.pbi_uid == getuid(), before.pbi_status != SZOMB else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro not imported by Swift.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let capacity = path.count
        let count = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32(capacity)) }
        let executable: String
        if count > 0 {
            executable = String(cString: path)
        } else {
            guard let latest = try info(pid: pid), latest.pbi_status != SZOMB,
                  latest.pbi_start_tvsec == before.pbi_start_tvsec,
                  latest.pbi_start_tvusec == before.pbi_start_tvusec else { return nil }
            // Long-lived plugin processes can outlive removal of their executable.
            // ps can still identify them, but this fallback NEVER grants signal authority.
            guard let cachedPath = try cachedExecutablePath(pid: pid) else { return nil }
            executable = cachedPath
        }
        guard let after = try info(pid: pid), after.pbi_uid == getuid(), after.pbi_status != SZOMB,
              before.pbi_start_tvsec == after.pbi_start_tvsec,
              before.pbi_start_tvusec == after.pbi_start_tvusec else { return nil }
        return ProcessEntry(pid: pid, executable: executable, parentPID: Int32(after.pbi_ppid),
                            startedSeconds: after.pbi_start_tvsec, startedMicroseconds: after.pbi_start_tvusec,
                            hasVerifiedExecutablePath: count > 0)
    }

    private static func cachedExecutablePath(pid: Int32) throws -> String? {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/ps")
        command.arguments = ["-p", String(pid), "-o", "comm="]
        let pipe = Pipe()
        command.standardOutput = pipe
        command.standardError = FileHandle.nullDevice
        try command.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        guard let latest = try info(pid: pid), latest.pbi_status != SZOMB else { return nil }
        guard command.terminationStatus == 0, let text = String(data: bytes, encoding: .utf8),
              text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") else {
            throw SwitchError("无法确认一个正在运行的 Codex 任务，因此没有切换账号。请结束相关任务后再试。")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func info(pid: Int32) throws -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        errno = 0
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        guard count == size else {
            if errno == ESRCH || (Darwin.kill(pid, 0) == -1 && errno == ESRCH) { return nil }
            throw SwitchError("无法确认一个正在运行的任务，因此没有切换账号。请稍后再试。")
        }
        return info
    }

    static func signal(_ expected: ProcessEntry, _ signal: ShutdownSignal) throws {
        guard expected.pid > 1, expected.pid != getpid(), expected.startedSeconds > 0,
              expected.isCodex, expected.hasVerifiedExecutablePath else {
            throw SwitchError("无法安全地结束 ChatGPT 相关进程，因此账号没有切换。")
        }
        // Check the kernel identity again immediately before signaling. Never signal
        // a replacement process just because it inherited an earlier PID or filename.
        guard let current = try entry(pid: expected.pid), current.hasVerifiedExecutablePath,
              current.isSameInstance(as: expected) else { return }
        let number = signal == .terminate ? SIGTERM : SIGKILL
        guard Darwin.kill(expected.pid, number) == 0 || errno == ESRCH else {
            throw SwitchError("无法结束 \(expected.summary)，账号没有切换。请手动退出 ChatGPT 后再试。")
        }
    }
}
