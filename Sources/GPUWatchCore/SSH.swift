import Foundation

/// A machine the app reads from, addressed by its real name so it works without any
/// `~/.ssh/config` entry, which a labmate's Mac won't have.
public struct Machine: Sendable, Equatable {
    /// What the app calls it, and the name of its fixture file.
    public let name: String
    let hostName: String
    /// A gateway reached first, as the same user.
    let jumpHost: String?
}

/// A UVA computing ID: the user the app signs in as on every machine.
public enum ComputingID {
    /// Lowercased and trimmed, or nil if it isn't a plausible ID. The ID goes into ssh's
    /// arguments and the scripts' paths, so nothing beyond letters and digits gets through.
    public static func normalized(_ text: String) -> String? {
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isPlain = id.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        guard isPlain, (2...16).contains(id.count), id.first?.isLetter == true else { return nil }
        return id
    }
}

/// Runs read-only scripts over SSH, signed in with the user's own keys.
public enum SSH {
    private static let executable = URL(fileURLWithPath: "/usr/bin/ssh")

    /// Sockets for reusing one connection between refreshes. This lives under `~/.ssh`
    /// because the path has to stay short: Unix socket paths are capped at 104 characters.
    private static var controlDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/gpuwatch-cm")
    }

    private static var controlPathOption: [String] {
        ["-o", "ControlPath=\(controlDirectory.path)/%C"]
    }

    private static var options: [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "LogLevel=ERROR",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=2",
            "-o", "ControlMaster=auto",
            // Outlives the longest refresh gap, and closes itself soon after the app quits.
            "-o", "ControlPersist=120",
        ] + controlPathOption
    }

    /// The jump goes through `ProxyCommand` rather than `-J`, because `-J` doesn't pass
    /// `BatchMode` on, and the gateway would then try to ask for a password.
    public static func connectionArguments(machine: Machine, user: String) -> [String] {
        let jump = machine.jumpHost.map { host in
            ["-o", "ProxyCommand=/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR -l \(user) -W %h:%p \(host)"]
        } ?? []
        return jump + ["-l", user, machine.hostName]
    }

    public static func run(on machine: Machine, as user: String, script: String, timeout: TimeInterval) async throws -> String {
        let host = machine.name
        if let fixtures = ProcessInfo.processInfo.environment["GPUWATCH_FIXTURES"] {
            return try readFixture(directory: fixtures, host: host)
        }
        do {
            try FileManager.default.createDirectory(
                at: controlDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let result = try await execute(arguments: options + connectionArguments(machine: machine, user: user) + [script], timeout: timeout)
            if result.timedOut {
                // A wedged shared connection would stall every later refresh too.
                await dropConnection(on: machine, as: user)
                throw describe(host: host, user: user, stderr: "Timed out after \(Int(timeout)) seconds")
            }
            // A script that reached its end is a success even if something printed to stderr.
            if result.status != 0 && !result.stdout.contains("@@END") {
                throw describe(host: host, user: user, stderr: result.stderr)
            }
            return result.stdout
        } catch let failure as FetchFailure {
            throw failure
        } catch {
            throw FetchFailure(headline: "Couldn't run ssh", detail: error.localizedDescription)
        }
    }

    /// Closes the shared connection, e.g. after waking from sleep when it is certainly dead.
    public static func dropConnection(on machine: Machine, as user: String) async {
        guard ProcessInfo.processInfo.environment["GPUWATCH_FIXTURES"] == nil else { return }
        _ = try? await execute(arguments: controlPathOption + ["-O", "exit"] + connectionArguments(machine: machine, user: user), timeout: 5)
    }

    private struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    /// Output goes to temp files, not pipes. `ControlPersist` backgrounds a master process that
    /// inherits these descriptors, so reading a pipe to EOF would hang for as long as it lives.
    private static func execute(arguments: [String], timeout: TimeInterval) async throws -> Result {
        let directory = FileManager.default.temporaryDirectory
        let outURL = directory.appendingPathComponent("gpuwatch-\(UUID().uuidString).out")
        let errURL = directory.appendingPathComponent("gpuwatch-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle

        let flag = TimeoutFlag()
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    flag.set()
                    process.terminate()
                }
            }
        }
        return Result(
            status: status,
            stdout: (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
            stderr: ((try? String(contentsOf: errURL, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            timedOut: flag.isSet
        )
    }

    /// Exposed for the checks. ssh's own wording is kept as the detail line.
    public static func describe(host: String, user: String, stderr: String) -> FetchFailure {
        let lower = stderr.lowercased()
        let detail = stderr.isEmpty ? "ssh exited without an error message." : stderr
        if lower.contains("permission denied") || lower.contains("too many authentication failures") {
            return FetchFailure(
                headline: "\(host) didn't accept the SSH key for \(user)",
                detail: "Check the computing ID, and that this Mac's key is set up for it. \(detail)"
            )
        }
        if lower.contains("could not resolve") {
            return FetchFailure(headline: "\(host) can't be found. Are you online?", detail: detail)
        }
        if lower.contains("timed out") || lower.contains("no route") || lower.contains("connection refused")
            || lower.contains("connection closed") || lower.contains("broken pipe") {
            let hint = host == RemoteScripts.hpcHost ? " Are you on the UVA network or VPN?" : ""
            return FetchFailure(headline: "Can't reach \(host).\(hint)", detail: detail)
        }
        return FetchFailure(headline: "Couldn't connect to \(host)", detail: detail)
    }

    /// `GPUWATCH_FIXTURES=<dir>` swaps ssh for canned `<host>.txt` replies, to exercise the UI
    /// with jobs and states the clusters aren't showing right now. A missing file acts unreachable.
    private static func readFixture(directory: String, host: String) throws -> String {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(host).txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw describe(host: host, user: "", stderr: "ssh: connect to host \(host) port 22: Operation timed out")
        }
        return text
    }
}
