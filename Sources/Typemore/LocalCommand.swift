import Foundation

struct LocalCommandResult { let status: Int32; let output: String; let error: String }

private final class CommandState: @unchecked Sendable {
    let lock = NSLock()
    var process: Process?
    var cancelled = false
    func attach(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        self.process = process
    }
    func cancel() {
        lock.lock(); cancelled = true; let process = process; lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

private final class CommandText: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ next: Data) { lock.lock(); defer { lock.unlock() }; if data.count < 1_048_576 { data.append(next) } }
    func text() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

enum LocalCommand {
    static func run(path: String, arguments: [String], directory: URL? = nil, timeout: TimeInterval = 90,
                    onOutput: (@Sendable (String) -> Void)? = nil) async throws -> LocalCommandResult {
        let state = CommandState()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) {
                try execute(path: path, arguments: arguments, directory: directory,
                            timeout: timeout, onOutput: onOutput, state: state)
            }.value
        }, onCancel: { state.cancel() })
    }
    private static func execute(path: String, arguments: [String], directory: URL?, timeout: TimeInterval,
                                onOutput: (@Sendable (String) -> Void)?, state: CommandState) throws -> LocalCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var nodeRoot = resolved
        for _ in 0..<6 { nodeRoot.deleteLastPathComponent() }
        let search = [URL(fileURLWithPath: path).deletingLastPathComponent().path,
                      nodeRoot.appendingPathComponent("bin").path,
                      "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = search.joined(separator: ":") + ":" + (env["PATH"] ?? "")
        env["DOUBAO_CLI_NO_UPDATE_CHECK"] = "1"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        try state.attach(process)
        try process.run()
        let output = CommandText(), errors = CommandText(), readers = DispatchGroup()
        for (handle, buffer) in [(out.fileHandleForReading, output), (err.fileHandleForReading, errors)] {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { readers.leave() }
                while let data = try? handle.read(upToCount: 4096), !data.isEmpty {
                    buffer.append(data)
                    onOutput?(buffer.text())
                }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline, !state.isCancelled() { Thread.sleep(forTimeInterval: 0.04) }
        let timedOut = process.isRunning && !state.isCancelled()
        if process.isRunning { process.terminate() }
        let stopDeadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        _ = readers.wait(timeout: .now() + 3)
        if state.isCancelled() { throw CancellationError() }
        if timedOut { throw ModelServiceError.message("连接等待超时，请重试") }
        return LocalCommandResult(status: process.terminationStatus, output: output.text(), error: errors.text())
    }

}
