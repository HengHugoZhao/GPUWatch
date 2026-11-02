import Foundation

public enum JobPhase: Sendable, Equatable {
    case running, pending, completing, suspended
    case completed, failed, cancelled, timedOut, outOfMemory, nodeFailed, preempted, other

    public init(slurmState raw: String) {
        // sacct reports "CANCELLED by 12345".
        switch raw.split(separator: " ").first.map(String.init) ?? raw {
        case "RUNNING", "CONFIGURING", "RESIZING": self = .running
        case "PENDING", "REQUEUED", "REQUEUE_HOLD", "SPECIAL_EXIT": self = .pending
        case "COMPLETING", "STAGE_OUT", "SIGNALING": self = .completing
        case "SUSPENDED", "STOPPED": self = .suspended
        case "COMPLETED": self = .completed
        case "FAILED", "BOOT_FAIL", "DEADLINE": self = .failed
        case "CANCELLED", "REVOKED": self = .cancelled
        case "TIMEOUT": self = .timedOut
        case "OUT_OF_MEMORY": self = .outOfMemory
        case "NODE_FAIL": self = .nodeFailed
        case "PREEMPTED": self = .preempted
        default: self = .other
        }
    }

    public var isActive: Bool {
        switch self {
        case .running, .pending, .completing, .suspended: return true
        default: return false
        }
    }

    public var label: String {
        switch self {
        case .running: return "Running"
        case .pending: return "Pending"
        case .completing: return "Completing"
        case .suspended: return "Suspended"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .timedOut: return "Timed out"
        case .outOfMemory: return "Out of memory"
        case .nodeFailed: return "Node failed"
        case .preempted: return "Preempted"
        case .other: return "Other"
        }
    }
}

public struct SlurmJob: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let partition: String
    public let state: String
    public let phase: JobPhase
    public let elapsedSeconds: Int?
    public let limitSeconds: Int?
    public let nodeCount: Int?
    public let cpus: Int?
    public let memory: String?
    public let gpus: String?
    public let gpuCount: Int?
    /// The job's whole reservation, unlike `memory`, which `squeue` can give per CPU.
    public let allocatedMemoryMB: Int?
    public let billing: Int?
    /// The node list once running; the pending reason, without its parentheses, before that.
    public let nodesOrReason: String?
    public let submitted: Date?
    public let started: Date?
    public let ended: Date?
    public let account: String?
    public let workDir: String?
    public let stdoutPath: String?
    public let exitCode: String?

    /// SUs an hour. MAM charges a tenth of Slurm's billing weight, on CPU and GPU jobs alike:
    /// `billing=1468` for 36,742 seconds was charged 1,498 SUs.
    public var creditsPerHour: Double? {
        billing.map { Double($0) / 10 }
    }

    public var creditsSoFar: Double? {
        guard let creditsPerHour, let elapsedSeconds else { return nil }
        return creditsPerHour * Double(elapsedSeconds) / 3600
    }

    public var pendingExplanation: String? {
        guard phase == .pending, let reason = nodesOrReason else { return nil }
        return Self.explain(pendingReason: reason)
    }

    /// Non-zero `exit:signal`, in words.
    public var exitSummary: String? {
        guard let exitCode, exitCode != "0:0" else { return nil }
        let parts = exitCode.split(separator: ":")
        if parts.count == 2, parts[1] != "0" { return "signal \(parts[1])" }
        return "exit \(parts.first ?? "?")"
    }

    /// Plain words for the common reasons. Only the first part of a multi-part reason
    /// such as `ReqNodeNotAvail, UnavailableNodes:udc-an1` is looked up.
    static func explain(pendingReason raw: String) -> String {
        let key = raw.split(separator: ",").first.map(String.init) ?? raw
        switch key {
        case "None": return "Waiting for the scheduler"
        case "Priority": return "Behind higher-priority jobs"
        case "Resources": return "Waiting for resources to free up"
        case "Dependency": return "Waiting on a job dependency"
        case "DependencyNeverSatisfied": return "Its dependency can never be met"
        case "BeginTime": return "Scheduled to start later"
        case "JobHeldUser": return "Held by you"
        case "JobHeldAdmin": return "Held by an administrator"
        case "JobArrayTaskLimit": return "At the array's running-task limit"
        case "QOSMaxGRESPerUser", "MaxGRESPerAccount": return "At your GPU limit"
        case "QOSMaxJobsPerUserLimit", "AssocMaxJobsLimit": return "At your running-job limit"
        case "QOSMaxCpuPerUserLimit": return "At your CPU limit"
        case "ReqNodeNotAvail": return "A required node is unavailable"
        case "PartitionTimeLimit": return "Time limit exceeds the partition's maximum"
        case "PartitionNodeLimit": return "Node count exceeds the partition's limit"
        case "BadConstraints": return "Its request can't be met; check constraints"
        case "InvalidAccount": return "Invalid account"
        case "InvalidQOS": return "Invalid QoS"
        case "AssocGrpBillingMinutes": return "Allocation is out of service units"
        default: return key
        }
    }
}

/// Parsing helpers shared by the squeue and sacct rows.
enum SlurmFormat {
    /// `1-14:17:40`, `02:05:18` or `17:40`. Nil for `UNLIMITED`, `INVALID`, `Partition_Limit`.
    static func seconds(_ raw: String) -> Int? {
        var days = 0
        var clock = Substring(raw)
        if let dash = raw.firstIndex(of: "-") {
            guard let d = Int(raw[..<dash]) else { return nil }
            days = d
            clock = raw[raw.index(after: dash)...]
        }
        let parts = clock.split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let clockSeconds = parts.reduce(0) { $0 * 60 + ($1 ?? 0) }
        return days * 86_400 + clockSeconds
    }

    /// Slurm prints times in the cluster's zone, as local clock time with no offset.
    /// `zoneLines` is the output of `date +%z` and `readlink -f /etc/localtime` on the cluster.
    static func dateParser(zoneLines: [String]) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = namedTimeZone(zoneLines) ?? timeZone(offset: zoneLines.first) ?? .current
        return formatter
    }

    /// `/usr/share/zoneinfo/America/New_York` → that zone. Today's offset alone would put a job
    /// ending after a daylight-saving change an hour off, so the offset is only the fallback.
    static func namedTimeZone(_ zoneLines: [String]) -> TimeZone? {
        for line in zoneLines {
            guard let range = line.range(of: "zoneinfo/") else { continue }
            if let zone = TimeZone(identifier: String(line[range.upperBound...])) { return zone }
        }
        return nil
    }

    static func timeZone(offset: String?) -> TimeZone? {
        guard let offset, offset.count == 5, let sign = offset.first, sign == "+" || sign == "-",
              let hours = Int(offset.dropFirst().prefix(2)), let minutes = Int(offset.suffix(2)) else { return nil }
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
    }

    static func tresValue(_ key: String, in tres: String) -> String? {
        for item in tres.split(separator: ",") where item.hasPrefix("\(key)=") {
            return String(item.dropFirst(key.count + 1))
        }
        return nil
    }

    /// `37434428K`, `186926M` or `64G`. Slurm leaves the unit off a plain byte count, such as `0`.
    static func megabytes(_ raw: String) -> Int? {
        let units: [Character: Double] = ["K": 1.0 / 1024, "M": 1, "G": 1024, "T": 1024 * 1024, "P": 1024 * 1024 * 1024]
        if let last = raw.last, let scale = units[last] {
            return Double(raw.dropLast()).map { Int(($0 * scale).rounded()) }
        }
        return Double(raw).map { Int(($0 / (1024 * 1024)).rounded()) }
    }

    /// `05:10:36`, `1-09:42:24`, or with a fraction of a second, `07:26.402`.
    static func cpuSeconds(_ raw: String) -> Double? {
        let parts = raw.split(separator: ".", maxSplits: 1).map(String.init)
        guard let whole = parts.first.flatMap(seconds) else { return nil }
        return Double(whole) + (parts.count == 2 ? Double("0.\(parts[1])") ?? 0 : 0)
    }

    /// "2 × a100" or "2 GPUs" from whichever of the TRES strings carries the detail:
    /// `gres/gpu=2`, `gres/gpu:a100=2` (sacct), `gres/gpu:a100:1` (squeue per-node request).
    static func gpuSummary(tres: [String]) -> String? {
        var count: Int?
        var type: String?
        for string in tres {
            for item in string.split(separator: ",") {
                if item.hasPrefix("gres/gpu=") {
                    count = Int(item.dropFirst("gres/gpu=".count)) ?? count
                } else if item.hasPrefix("gres/gpu:") || item.hasPrefix("gres:gpu:") || item.hasPrefix("gpu:") {
                    let rest = item.drop { $0 != ":" }.dropFirst()
                    let pieces = rest.split(whereSeparator: { $0 == ":" || $0 == "=" })
                    if pieces.count == 2, let n = Int(pieces[1]) {
                        type = String(pieces[0])
                        count = count ?? n
                    } else if pieces.count == 1, let n = Int(pieces[0]) {
                        count = count ?? n
                    }
                }
            }
        }
        guard let count, count > 0 else { return nil }
        if let type { return "\(count) × \(type)" }
        return count == 1 ? "1 GPU" : "\(count) GPUs"
    }

    static func cleaned(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw != "N/A", raw != "None assigned", raw != "(null)", raw != "Unknown" else { return nil }
        return raw
    }
}

extension SlurmJob {
    /// One row of the `RemoteScripts.squeueFields` format.
    static func parse(squeueLine line: String, dates: DateFormatter) -> SlurmJob? {
        var fields = line.components(separatedBy: "|")
        if fields.last == "" { fields.removeLast() }
        let columnCount = RemoteScripts.squeueFields.count
        guard fields.count >= columnCount else { return nil }
        // The job name is the last column and the only one a user can put a `|` in.
        let name = fields[(columnCount - 1)...].joined(separator: "|")
        let state = fields[2]
        guard !fields[0].isEmpty, !state.isEmpty else { return nil }

        let phase = JobPhase(slurmState: state)
        let reasonList = fields[11].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        return SlurmJob(
            id: fields[0],
            name: name,
            partition: fields[1],
            state: state,
            phase: phase,
            elapsedSeconds: SlurmFormat.seconds(fields[3]),
            limitSeconds: SlurmFormat.seconds(fields[4]),
            nodeCount: Int(fields[5]),
            cpus: Int(fields[6]),
            memory: SlurmFormat.cleaned(fields[7]),
            gpus: SlurmFormat.gpuSummary(tres: [fields[8], fields[9], fields[10]]),
            gpuCount: SlurmFormat.tresValue("gres/gpu", in: fields[10]).flatMap { Int($0) },
            allocatedMemoryMB: SlurmFormat.tresValue("mem", in: fields[10]).flatMap(SlurmFormat.megabytes),
            billing: SlurmFormat.tresValue("billing", in: fields[10]).flatMap { Int($0) },
            nodesOrReason: SlurmFormat.cleaned(reasonList),
            submitted: dates.date(from: fields[12]),
            started: dates.date(from: fields[13]),
            ended: dates.date(from: fields[14]),
            account: SlurmFormat.cleaned(fields[15]),
            workDir: SlurmFormat.cleaned(fields[16]),
            stdoutPath: SlurmFormat.cleaned(fields[17]),
            exitCode: nil
        )
    }

    /// One row of the `RemoteScripts.sacctFields` format.
    static func parse(sacctLine line: String, dates: DateFormatter) -> SlurmJob? {
        let fields = line.components(separatedBy: "|")
        let columnCount = RemoteScripts.sacctFields.count
        guard fields.count >= columnCount, !fields[0].isEmpty else { return nil }
        let name = fields[(columnCount - 1)...].joined(separator: "|")
        let tres = fields[6]
        return SlurmJob(
            id: fields[0],
            name: name,
            partition: fields[1],
            state: fields[2],
            phase: JobPhase(slurmState: fields[2]),
            elapsedSeconds: SlurmFormat.seconds(fields[3]),
            limitSeconds: SlurmFormat.seconds(fields[4]),
            nodeCount: SlurmFormat.tresValue("node", in: tres).flatMap { Int($0) },
            cpus: SlurmFormat.tresValue("cpu", in: tres).flatMap { Int($0) },
            memory: SlurmFormat.tresValue("mem", in: tres),
            gpus: SlurmFormat.gpuSummary(tres: [tres]),
            gpuCount: SlurmFormat.tresValue("gres/gpu", in: tres).flatMap { Int($0) },
            allocatedMemoryMB: SlurmFormat.tresValue("mem", in: tres).flatMap(SlurmFormat.megabytes),
            billing: SlurmFormat.tresValue("billing", in: tres).flatMap { Int($0) },
            nodesOrReason: SlurmFormat.cleaned(fields[10]),
            submitted: dates.date(from: fields[7]),
            started: dates.date(from: fields[8]),
            ended: dates.date(from: fields[9]),
            account: SlurmFormat.cleaned(fields[11]),
            workDir: SlurmFormat.cleaned(fields[12]),
            stdoutPath: nil,
            exitCode: SlurmFormat.cleaned(fields[5])
        )
    }
}
