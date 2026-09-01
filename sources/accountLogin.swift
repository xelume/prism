import Foundation
import Darwin

enum CodexExecutable {
    static func resolve(configuredPath: String?, searchPaths: [String]) throws -> URL {
        if let configuredPath, !configuredPath.isEmpty {
            guard let executable = validate(configuredPath) else {
                throw SwitchError("无法使用指定的 Codex CLI，请检查设置。")
            }
            return executable
        }
        for path in searchPaths {
            if let executable = validate(path) { return executable }
        }
        throw SwitchError("没有找到可用的 Codex，请先完成安装。")
    }

    private static func validate(_ path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == 0 || info.st_uid == getuid(),
              info.st_mode & 0o022 == 0,
              access(url.path, X_OK) == 0 else { return nil }
        return url
    }
}

struct AccountLogin {
    static func remember(_ data: Data, expectedIdentity: String?, in book: inout AccountBook) throws -> SavedAccount {
        let snapshot = try AuthSnapshot(data)
        if let expectedIdentity, snapshot.identity != expectedIdentity {
            throw SwitchError("登录的不是原账号，请重新登录。")
        }
        book.remember(snapshot)
        guard let account = book.accounts.first(where: { $0.identity == snapshot.identity }) else {
            throw SwitchError("无法保存这个账号，请再试一次。")
        }
        return account
    }

    static func run(executable: URL, timeout: TimeInterval = 180,
                    terminationGrace: TimeInterval = 1) async throws -> Data {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["login", "-c", "cli_auth_credentials_store=\"file\""]
        var environment = ProcessInfo.processInfo.environment
        for key in ["CODEX_ACCESS_TOKEN", "CODEX_API_KEY", "CODEX_AUTH_JSON", "OPENAI_API_KEY"] {
            environment.removeValue(forKey: key)
        }
        environment["CODEX_HOME"] = directory.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let waiter = LoginProcessWaiter(process: process, timeout: timeout, terminationGrace: terminationGrace)
        let status = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await waiter.run()
        } onCancel: {
            waiter.cancel()
        }
        guard status == 0 else {
            throw SwitchError("登录未完成或已取消。")
        }
        let file = try AuthFile(home: directory)
        guard let data = try file.read() else {
            throw SwitchError("未能获取账号信息，请重新登录。")
        }
        _ = try AuthSnapshot(data)
        return data
    }

    private static func temporaryDirectory() throws -> URL {
        var template = Array((NSTemporaryDirectory() + "prism-account-login.XXXXXX").utf8CString)
        let path: String? = template.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress, let result = mkdtemp(base) else { return nil }
            return String(cString: result)
        }
        guard let path else { throw SwitchError("无法开始登录，请稍后再试。") }
        guard chmod(path, 0o700) == 0 else {
            try? FileManager.default.removeItem(atPath: path)
            throw SwitchError("无法开始登录，请检查文件权限。")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

}

private final class LoginProcessWaiter: @unchecked Sendable {
    private enum StopReason { case canceled, timedOut }

    private let process: Process
    private let timeout: TimeInterval
    private let terminationGrace: TimeInterval
    private let lock = NSLock()
    private var stopReason: StopReason?
    private var started = false

    init(process: Process, timeout: TimeInterval, terminationGrace: TimeInterval) {
        self.process = process
        self.timeout = timeout
        self.terminationGrace = terminationGrace
    }

    func run() async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if stopReason == .canceled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            process.terminationHandler = { [weak self] finished in
                guard let self else { return }
                self.lock.lock()
                let reason = self.stopReason
                self.lock.unlock()
                switch reason {
                case .canceled: continuation.resume(throwing: CancellationError())
                case .timedOut: continuation.resume(throwing: SwitchError("等待登录超时。当前账号和已保存的账号都没有改变。"))
                case nil: continuation.resume(returning: finished.terminationStatus)
                }
            }
            do {
                try process.run()
                started = true
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.stop(.timedOut)
                }
            } catch {
                process.terminationHandler = nil
                lock.unlock()
                continuation.resume(throwing: SwitchError("无法打开登录页面，请检查 Codex 是否已安装。"))
            }
        }
    }

    func cancel() { stop(.canceled) }

    private func stop(_ reason: StopReason) {
        lock.lock()
        guard stopReason == nil else { lock.unlock(); return }
        stopReason = reason
        let shouldStop = started && process.isRunning
        let pid = process.processIdentifier
        lock.unlock()
        guard shouldStop else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + terminationGrace) { [weak process] in
            guard let process, process.isRunning, process.processIdentifier == pid else { return }
            Darwin.kill(pid, SIGKILL)
        }
    }
}
