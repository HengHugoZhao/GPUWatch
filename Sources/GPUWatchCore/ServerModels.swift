import Foundation

/// A process holding memory on one of ZheServer's GPUs.
public struct GPUProcess: Identifiable, Sendable, Hashable {
    public let pid: Int
    public let user: String?
    public let memoryMiB: Int?
    public let elapsedSeconds: Int?
    public let executable: String
    public let commandLine: String?
    public let parentPID: Int?
    public let workDir: String?

    public var id: Int { pid }

    /// What makes processes one job. Older launchers pass each worker its rank as an argument,
    /// which shouldn't split a job.
    var jobKey: String {
        let arguments = (commandLine ?? executable)
            .replacingOccurrences(of: #"\s*--local[-_]rank[= ]\d+"#, with: "", options: .regularExpression)
        return "\(parentPID ?? pid) \(arguments)"
    }

    /// `python3.12 train.py` rather than a 200-character env path and flag list.
    public var shortCommand: String {
        let exe = (executable as NSString).lastPathComponent
        guard let commandLine else { return exe }
        let script = commandLine.split(separator: " ").dropFirst().first { !$0.hasPrefix("-") }
        guard let script else { return exe }
        return "\(exe) \((String(script) as NSString).lastPathComponent)"
    }
}

/// GPU processes that belong together. Workers from one launcher share a parent and a command
/// line, so four `finetune.py` workers are one job on four GPUs. Two runs started from one shell
/// share a parent too, but their arguments tell them apart.
public struct ServerJob: Identifiable, Sendable {
    public let pids: [Int]
    public let gpuIndexes: [Int]
    public let shortCommand: String
    public let commandLine: String?
    public let workDir: String?
    public let memoryMiB: Int?
    /// What the GPUs it's on hold between them.
    public let gpuMemoryTotalMiB: Int
    public let elapsedSeconds: Int?
    /// Across its GPU processes and their children, such as data loader workers. Nil if the
    /// server didn't report them.
    public let cpuSeconds: Double?
    /// Added up per process, so memory that forked workers share counts once for each of them.
    public let ramMB: Int?

    public var id: String { "server-\(pids.first ?? 0)" }

    /// How many cores it has kept busy on average since it started. Processes that have already
    /// exited aren't counted, since `ps` can no longer see them.
    public var cpuCores: Double? {
        guard let cpuSeconds, let elapsedSeconds, elapsedSeconds > 0 else { return nil }
        return cpuSeconds / Double(elapsedSeconds)
    }
}

/// One of the user's processes, GPU or not, for adding up what a job uses.
struct OwnProcess: Sendable {
    let pid: Int
    let parentPID: Int
    let cpuSeconds: Double
    let ramKB: Int

    /// `644095 643959 116498 3722376`: PID, parent, CPU seconds, resident KB.
    init?(psLine line: String) {
        let fields = line.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard fields.count == 4 else { return nil }
        (pid, parentPID, cpuSeconds, ramKB) = (fields[0], fields[1], Double(fields[2]), fields[3])
    }
}

public enum GPUAvailability: Sendable {
    case free, partlyFree, full

    /// A GPU counts as partly free when at least this share of its memory is unused.
    public static let partlyFreeThreshold = 0.20
    /// An idle GPU still holds a little memory for the driver.
    static let idleMemoryFraction = 0.05
}

public struct ServerGPU: Identifiable, Sendable {
    public let index: Int
    public let name: String
    public let uuid: String
    public let memoryUsedMiB: Int
    public let memoryTotalMiB: Int
    public let utilizationPercent: Int?
    public let temperatureC: Int?
    public let powerDrawW: Double?
    public let powerLimitW: Double?
    public var processes: [GPUProcess] = []

    public var id: Int { index }
    public var memoryFreeMiB: Int { max(memoryTotalMiB - memoryUsedMiB, 0) }

    public var memoryFraction: Double {
        memoryTotalMiB > 0 ? Double(memoryUsedMiB) / Double(memoryTotalMiB) : 0
    }

    public var availability: GPUAvailability {
        if processes.isEmpty && memoryFraction < GPUAvailability.idleMemoryFraction { return .free }
        return 1 - memoryFraction >= GPUAvailability.partlyFreeThreshold ? .partlyFree : .full
    }
}

/// The machine's CPU memory. "In use" is everything Linux can't hand to a new process,
/// so reclaimable disk cache doesn't count against it.
public struct SystemMemory: Sendable, Equatable {
    public let totalMB: Int
    public let availableMB: Int

    public var usedMB: Int { max(totalMB - availableMB, 0) }

    /// Parses the `MemTotal:  1584953792 kB` lines of `/proc/meminfo`.
    init?(meminfo lines: [String]) {
        var valuesKB: [String: Int] = [:]
        for line in lines {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, let value = Int(fields[1]) else { continue }
            valuesKB[String(fields[0])] = value
        }
        guard let total = valuesKB["MemTotal:"], let available = valuesKB["MemAvailable:"], total > 0 else { return nil }
        totalMB = total / 1024
        availableMB = available / 1024
    }
}

public struct ServerSnapshot: Sendable {
    public let me: String
    public let hostname: String
    public let gpus: [ServerGPU]
    /// Nil if the server didn't report it; that shouldn't cost the GPU view.
    public let memory: SystemMemory?
    public let cpuCount: Int?
    let ownProcesses: [OwnProcess]
    public let storage: StorageUsage?
    public let storageError: String?

    /// The user's jobs, newest first.
    public var myJobs: [ServerJob] {
        var groups: [String: [(gpu: Int, process: GPUProcess)]] = [:]
        for gpu in gpus {
            for process in gpu.processes where process.user == me {
                groups[process.jobKey, default: []].append((gpu.index, process))
            }
        }
        let gpuPIDs = Set(gpus.flatMap { $0.processes.map(\.pid) })
        let children = Dictionary(grouping: ownProcesses, by: \.parentPID)
        let totalMemory = Dictionary(uniqueKeysWithValues: gpus.map { ($0.index, $0.memoryTotalMiB) })
        return groups.values.map { members in
            let first = members[0].process
            let memory = members.compactMap { $0.process.memoryMiB }
            let pids = Set(members.map { $0.process.pid })
            let gpuIndexes = Set(members.map { $0.gpu })
            let family = Self.withDescendants(of: pids, children: children, stoppingAt: gpuPIDs)
            let measured = ownProcesses.filter { family.contains($0.pid) }
            return ServerJob(
                pids: pids.sorted(),
                gpuIndexes: gpuIndexes.sorted(),
                shortCommand: first.shortCommand,
                commandLine: first.commandLine,
                workDir: first.workDir,
                memoryMiB: memory.isEmpty ? nil : memory.reduce(0, +),
                gpuMemoryTotalMiB: gpuIndexes.compactMap { totalMemory[$0] }.reduce(0, +),
                elapsedSeconds: members.compactMap { $0.process.elapsedSeconds }.max(),
                cpuSeconds: measured.isEmpty ? nil : measured.map(\.cpuSeconds).reduce(0, +),
                ramMB: measured.isEmpty ? nil : measured.map(\.ramKB).reduce(0, +) / 1024
            )
        }
        .sorted { a, b in
            let (aElapsed, bElapsed) = (a.elapsedSeconds ?? .max, b.elapsedSeconds ?? .max)
            return aElapsed != bElapsed ? aElapsed < bElapsed : a.id < b.id
        }
    }

    /// A child holding GPU memory of its own is listed under its own job, so it isn't counted here too.
    private static func withDescendants(of pids: Set<Int>, children: [Int: [OwnProcess]], stoppingAt gpuPIDs: Set<Int>) -> Set<Int> {
        var family = pids
        var waiting = Array(pids)
        while let pid = waiting.popLast() {
            for child in children[pid] ?? [] where !gpuPIDs.contains(child.pid) && family.insert(child.pid).inserted {
                waiting.append(child.pid)
            }
        }
        return family
    }

    public func count(_ availability: GPUAvailability) -> Int {
        gpus.filter { $0.availability == availability }.count
    }

    /// "8 × NVIDIA RTX PRO 6000", with one entry per distinct model.
    public var hardwareSummary: String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for gpu in gpus {
            if counts[gpu.name] == nil { order.append(gpu.name) }
            counts[gpu.name, default: 0] += 1
        }
        return order.map { "\(counts[$0]!) × \($0)" }.joined(separator: ", ")
    }
}

// MARK: - Parsing

extension ServerSnapshot {
    public static func parse(_ text: String) throws -> ServerSnapshot {
        let output = RemoteOutput(text)
        guard output.isComplete else {
            throw FetchFailure(headline: "The connection dropped mid-update", detail: "The server's reply was incomplete.")
        }
        guard let gpuSection = output.sections["GPUS"] else {
            throw FetchFailure(headline: "Unexpected reply from the server", detail: "No GPU section in the output.")
        }
        if let message = gpuSection.failureMessage {
            throw FetchFailure(headline: "nvidia-smi failed on the server", detail: message)
        }

        let owners = parseOwners(output.sections["PS"]?.lines ?? [])
        let workDirs = parseWorkDirs(output.sections["CWD"]?.lines ?? [])
        var processesByGPU: [String: [GPUProcess]] = [:]
        for line in output.sections["APPS"]?.lines ?? [] {
            let fields = csvFields(line, maxFields: 4)
            guard fields.count == 4, let pid = Int(fields[1]) else { continue }
            let owner = owners[pid]
            processesByGPU[fields[0], default: []].append(GPUProcess(
                pid: pid,
                user: owner?.user,
                memoryMiB: Int(fields[2]),
                elapsedSeconds: owner?.elapsed,
                executable: fields[3],
                commandLine: owner?.command,
                parentPID: owner?.parent,
                workDir: workDirs[pid]
            ))
        }

        let gpus: [ServerGPU] = gpuSection.lines.compactMap { line in
            let fields = csvFields(line, maxFields: 9)
            guard fields.count == 9, let index = Int(fields[0]),
                  let used = Int(fields[3]), let total = Int(fields[4]) else { return nil }
            return ServerGPU(
                index: index,
                name: fields[1],
                uuid: fields[2],
                memoryUsedMiB: used,
                memoryTotalMiB: total,
                utilizationPercent: Int(fields[5]),
                temperatureC: Int(fields[6]),
                powerDrawW: Double(fields[7]),
                powerLimitW: Double(fields[8]),
                processes: processesByGPU[fields[2]] ?? []
            )
        }
        guard !gpus.isEmpty else {
            throw FetchFailure(headline: "No GPUs reported", detail: "nvidia-smi returned no readable GPU rows.")
        }
        let diskSection = output.sections["DISK"]
        let target = RemoteScripts.serverStorage
        let storage = diskSection?.exitCode == 0 ? StorageUsage(target: target, dfLines: diskSection?.lines ?? []) : nil
        return ServerSnapshot(
            me: output.firstLine("ME") ?? "",
            hostname: output.firstLine("HOST") ?? "",
            gpus: gpus.sorted { $0.index < $1.index },
            memory: SystemMemory(meminfo: output.sections["MEM"]?.lines ?? []),
            cpuCount: output.firstLine("CPUS").flatMap { Int($0) },
            ownProcesses: (output.sections["MYPS"]?.lines ?? []).compactMap(OwnProcess.init(psLine:)),
            storage: storage,
            storageError: diskSection?.failureMessage ?? (storage == nil ? "Not reported" : nil)
        )
    }

    private static func csvFields(_ line: String, maxFields: Int) -> [String] {
        line.split(separator: ",", maxSplits: maxFields - 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseOwners(_ lines: [String]) -> [Int: (user: String, parent: Int?, elapsed: Int?, command: String)] {
        var owners: [Int: (user: String, parent: Int?, elapsed: Int?, command: String)] = [:]
        for line in lines {
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count == 5, let pid = Int(fields[0]) else { continue }
            owners[pid] = (String(fields[1]), Int(fields[2]), Int(fields[3]), String(fields[4]))
        }
        return owners
    }

    /// `644095 /p/simple/run`. Other users' processes aren't readable, so they aren't listed.
    private static func parseWorkDirs(_ lines: [String]) -> [Int: String] {
        var workDirs: [Int: String] = [:]
        for line in lines {
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2, let pid = Int(fields[0]) else { continue }
            workDirs[pid] = String(fields[1])
        }
        return workDirs
    }
}
