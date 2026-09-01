import Foundation
import Darwin

enum CodexExecutable {
    static func resolve(configuredPath: String?, searchPaths: [String]) throws -> URL {
        if let configuredPath, !configuredPath.isEmpty {
            guard let executable = validate(configuredPath) else {
                throw SwitchError("CODEX_CLI_PATH 指向的文件不存在、不可执行或权限不安全。")
            }
            return executable
        }
        for path in searchPaths {
            if let executable = validate(path) { return executable }
        }
        throw SwitchError("未找到可用的 Codex CLI。请安装 Codex CLI，或通过 CODEX_CLI_PATH 指定其完整路径。")
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
            throw SwitchError("登录的账号与需要重新认证的账号不一致，未修改任何账号备份。")
        }
        book.remember(snapshot)
        guard let account = book.accounts.first(where: { $0.identity == snapshot.identity }) else {
            throw SwitchError("登录认证未能保存到账号列表。")
        }
        return account
    }

    static func run(executable: URL, timeout: TimeInterval = 600) async throws -> Data {
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

        let status = try await terminationStatus(of: process, timeout: timeout)
        guard status == 0 else {
            throw SwitchError("Codex 登录未完成或已取消，当前登录和账号备份均未修改。")
        }
        let file = try AuthFile(home: directory)
        guard let data = try file.read() else {
            throw SwitchError("Codex 登录完成后没有生成文件认证，未修改账号备份。")
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
        guard let path else { throw SwitchError("无法创建隔离登录目录。") }
        guard chmod(path, 0o700) == 0 else {
            try? FileManager.default.removeItem(atPath: path)
            throw SwitchError("无法保护隔离登录目录。")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func terminationStatus(of process: Process, timeout: TimeInterval) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let timeoutWork = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            process.terminationHandler = { finished in
                timeoutWork.cancel()
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            } catch {
                timeoutWork.cancel()
                process.terminationHandler = nil
                continuation.resume(throwing: SwitchError("无法启动 Codex 登录组件。"))
            }
        }
    }
}
