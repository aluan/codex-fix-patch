import AppKit
import Foundation
import Security

struct CommandResult: Sendable {
    let status: Int32
    let output: String
}

protocol CommandExecuting: Sendable {
    func run(_ executable: String, arguments: [String]) throws -> CommandResult
}

struct SystemCommandExecutor: CommandExecuting {
    func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

struct CodexProcessIdentity: Equatable, Sendable {
    let pid: pid_t
    let command: String
    let startedAt: String
    let cdpPort: UInt16?

    var key: String { "\(pid):\(startedAt)" }
}

struct CodexInstallation: Sendable {
    let appURL: URL
    let executableURL: URL
}

struct CodexSkinLifecycle: Sendable {
    static let cdpPort: UInt16 = 9_341
    private let executor: any CommandExecuting

    init(executor: any CommandExecuting = SystemCommandExecutor()) {
        self.executor = executor
    }

    func resolveInstallation() throws -> CodexInstallation {
        let candidates = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            AppPaths.home.appendingPathComponent("Applications/ChatGPT.app"),
        ]
        guard let appURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw SkinError.missingCodex
        }
        guard let bundle = Bundle(url: appURL),
              bundle.bundleIdentifier == "com.openai.codex",
              signingTeamID(at: appURL) == "2DC432GLL2" else {
            throw SkinError.untrustedCodex
        }
        let executable = appURL.appendingPathComponent("Contents/MacOS/ChatGPT")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw SkinError.untrustedCodex }
        return CodexInstallation(appURL: appURL, executableURL: executable)
    }

    func runningProcess(for installation: CodexInstallation) throws -> CodexProcessIdentity? {
        let result = try executor.run("/bin/ps", arguments: ["-axo", "pid=,lstart=,command="])
        guard result.status == 0 else { return nil }
        let prefix = installation.executableURL.path
        for line in result.output.split(separator: "\n") {
            let parts = line.split(maxSplits: 6, whereSeparator: \Character.isWhitespace)
            guard parts.count == 7, let pid = Int32(parts[0]) else { continue }
            let command = String(parts[6]).trimmingCharacters(in: .whitespaces)
            guard command == prefix || command.hasPrefix(prefix + " ") else { continue }
            let port = Self.debugPort(in: command)
            return CodexProcessIdentity(
                pid: pid,
                command: command,
                startedAt: parts[1...5].joined(separator: " "),
                cdpPort: port
            )
        }
        return nil
    }

    func verifyPortOwner(_ process: CodexProcessIdentity, installation: CodexInstallation) throws {
        let result = try executor.run("/usr/sbin/lsof", arguments: [
            "-nP", "-iTCP:\(Self.cdpPort)", "-sTCP:LISTEN", "-t",
        ])
        guard result.status == 0 else { throw SkinError.cdpUnavailable }
        let owners = Set(result.output.split(whereSeparator: \Character.isWhitespace).compactMap { Int32($0) })
        guard !owners.isEmpty else { throw SkinError.cdpUnavailable }
        let tree = try executor.run("/bin/ps", arguments: ["-axo", "pid=,ppid="])
        guard tree.status == 0 else { throw SkinError.cdpPortOccupied }
        var parents: [pid_t: pid_t] = [:]
        for line in tree.output.split(separator: "\n") {
            let columns = line.split(whereSeparator: \Character.isWhitespace)
            if columns.count == 2, let pid = Int32(columns[0]), let parent = Int32(columns[1]) {
                parents[pid] = parent
            }
        }
        guard owners.allSatisfy({ Self.isDescendant($0, of: process.pid, parents: parents) }) else {
            throw SkinError.cdpPortOccupied
        }
        guard try runningProcess(for: installation)?.key == process.key else { throw SkinError.cdpPortOccupied }
    }

    func ensureCDPPortAvailable() throws {
        let result = try executor.run("/usr/sbin/lsof", arguments: [
            "-nP", "-iTCP:\(Self.cdpPort)", "-sTCP:LISTEN", "-t",
        ])
        if result.status == 0, !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SkinError.cdpPortOccupied
        }
        guard result.status == 0 || result.status == 1 else { throw SkinError.cdpPortOccupied }
    }

    func restart(_ process: CodexProcessIdentity, installation: CodexInstallation, withCDP: Bool) async throws {
        guard try runningProcess(for: installation)?.key == process.key else { throw SkinError.codexDidNotQuit }
        guard let running = NSRunningApplication(processIdentifier: process.pid), running.terminate() else {
            throw SkinError.codexDidNotQuit
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if try runningProcess(for: installation)?.key != process.key { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard try runningProcess(for: installation)?.key != process.key else { throw SkinError.codexDidNotQuit }
        if process.cdpPort == Self.cdpPort {
            try await waitForPortRelease()
        }
        try launch(installation, withCDP: withCDP)
    }

    func launch(_ installation: CodexInstallation, withCDP: Bool) throws {
        var arguments = ["-na", installation.appURL.path]
        if withCDP {
            arguments.append(contentsOf: [
                "--args",
                "--remote-debugging-address=127.0.0.1",
                "--remote-debugging-port=\(Self.cdpPort)",
            ])
        }
        let launch = try executor.run("/usr/bin/open", arguments: arguments)
        guard launch.status == 0 else { throw SkinError.injectionFailed(launch.output) }
    }

    func waitForCDP(installation: CodexInstallation) async throws -> CodexProcessIdentity {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let process = try runningProcess(for: installation), process.cdpPort == Self.cdpPort {
                do {
                    try verifyPortOwner(process, installation: installation)
                    return process
                } catch SkinError.cdpUnavailable {
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw SkinError.cdpUnavailable
    }

    private func waitForPortRelease() async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let result = try executor.run("/usr/sbin/lsof", arguments: [
                "-nP", "-iTCP:\(Self.cdpPort)", "-sTCP:LISTEN", "-t",
            ])
            if result.status != 0 || result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw SkinError.cdpPortOccupied
    }

    private func signingTeamID(at url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [CFString: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier] as? String
    }

    static func debugPort(in command: String) -> UInt16? {
        let pattern = #"(?:^|\s)--remote-debugging-port(?:=|\s+)(\d+)(?=\s|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let range = Range(match.range(at: 1), in: command) else { return nil }
        return UInt16(command[range])
    }

    private static func isDescendant(_ pid: pid_t, of root: pid_t, parents: [pid_t: pid_t]) -> Bool {
        var current = pid
        var visited = Set<pid_t>()
        while current > 0, visited.insert(current).inserted {
            if current == root { return true }
            guard let parent = parents[current] else { return false }
            current = parent
        }
        return false
    }
}
