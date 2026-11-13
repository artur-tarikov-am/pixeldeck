import Foundation

struct SubprocessFailure: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

enum Subprocess {
    /// Where tools usually live, for a shell that cannot tell.
    private static let usualPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    private static let shellTimeoutSeconds: Double = 10

    /// An app started from Finder or at login gets a minimal PATH, so tools are looked up the way Terminal finds them.
    private static let searchPath = Task { await terminalPath() }

    /// Runs without a shell, so arguments stay arguments. Returns stdout.
    static func run(_ command: [String], timeoutSeconds: Double) async throws -> Data {
        try await run(command, path: await searchPath.value, timeoutSeconds: timeoutSeconds)
    }

    /// The PATH of an interactive login shell of the user, which reads the same files as a Terminal window.
    /// Its last line is taken, since the shell may print a greeting first.
    private static func terminalPath() async -> String {
        let shell = getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        let output = try? await run(
            [shell, "-l", "-i", "-c", "/usr/bin/printenv PATH"], path: usualPath, timeoutSeconds: shellTimeoutSeconds
        )
        let shellPath = output.flatMap { String(decoding: $0, as: UTF8.self).split(separator: "\n").last } ?? ""
        var seen: Set<Substring> = []
        return (shellPath.split(separator: ":") + usualPath.split(separator: ":"))
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
    }

    private static func run(_ command: [String], path: String, timeoutSeconds: Double) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": path]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: SubprocessFailure(message: error.localizedDescription))
                    return
                }
                let deadline = DispatchWorkItem { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: deadline)

                // Both pipes have to drain while the process runs, or a long answer blocks it forever.
                let group = DispatchGroup()
                nonisolated(unsafe) var stderr = Data()
                group.enter()
                DispatchQueue.global().async {
                    stderr = errors.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let stdout = output.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                deadline.cancel()

                if process.terminationStatus == 0, process.terminationReason == .exit {
                    continuation.resume(returning: stdout)
                } else {
                    continuation.resume(throwing: SubprocessFailure(message: failureMessage(process, stderr)))
                }
            }
        }
    }

    private static func failureMessage(_ process: Process, _ stderr: Data) -> String {
        let text = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return process.terminationReason == .exit
            ? "exit code \(process.terminationStatus)"
            : "stopped by timeout or signal \(process.terminationStatus)"
    }
}
