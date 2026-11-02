import Foundation

/// What a job actually used, as opposed to what it reserved. Past steps come from `sacct` and
/// running ones from `sstat`, which is why one job can have both.
public struct JobUsage: Sendable, Equatable {
    public let cpuSeconds: Double
    public let peakMemoryMB: Int
    /// Only while the job runs. A finished job only has its peak.
    public let currentMemoryMB: Int?
    /// Slurm's one figure for the job, added up across its GPUs: two GPUs near full read about 190.
    /// All 286 steps checked had the same "average" and "max", so it can't be told which it is.
    public let gpuUtilization: Double
    /// Also across the job's GPUs: 2 × 96 GB cards have read 192,176 MB.
    public let gpuMemoryMB: Int

    /// Zero for both is what a job with an unread GPU and a job that never touched it look like.
    /// A job holding memory at 0% really was idle, so that one still counts as a reading.
    public var hasGPUReading: Bool {
        gpuUtilization > 0 || gpuMemoryMB > 0
    }

    /// Over all the core time reserved, the way `seff` works it out.
    public func cpuFraction(cpus: Int?, elapsedSeconds: Int?) -> Double? {
        guard let cpus, let elapsedSeconds, cpus > 0, elapsedSeconds > 0 else { return nil }
        return cpuSeconds / Double(cpus * elapsedSeconds)
    }

    public func gpuFraction(gpus: Int?) -> Double? {
        guard let gpus, gpus > 0, hasGPUReading else { return nil }
        return gpuUtilization / Double(gpus) / 100
    }

    /// One step's `TRESUsageInTot` and `TRESUsageInMax`. For a running step the total is its
    /// use right now and the max its peak; for a finished one they hold the same peak.
    private struct Reading {
        let cpuSeconds: Double
        let memoryMB: Int
        let peakMemoryMB: Int
        let gpuUtilization: Double
        let gpuMemoryMB: Int
        let isLive: Bool

        init?(total: String, peak: String, isLive: Bool) {
            guard !total.isEmpty else { return nil }
            cpuSeconds = SlurmFormat.tresValue("cpu", in: total).flatMap(SlurmFormat.cpuSeconds) ?? 0
            memoryMB = SlurmFormat.tresValue("mem", in: total).flatMap(SlurmFormat.megabytes) ?? 0
            peakMemoryMB = max(memoryMB, SlurmFormat.tresValue("mem", in: peak).flatMap(SlurmFormat.megabytes) ?? 0)
            gpuUtilization = SlurmFormat.tresValue("gres/gpuutil", in: total).flatMap { Double($0) } ?? 0
            gpuMemoryMB = SlurmFormat.tresValue("gres/gpumem", in: total).flatMap(SlurmFormat.megabytes) ?? 0
            self.isLive = isLive
        }
    }

    private init(readings: [Reading]) {
        let live = readings.filter(\.isLive)
        // A running job's finished steps count towards its CPU time, but not towards what it's doing now.
        let now = live.isEmpty ? readings : live
        cpuSeconds = readings.map(\.cpuSeconds).reduce(0, +)
        peakMemoryMB = readings.map(\.peakMemoryMB).max() ?? 0
        currentMemoryMB = live.isEmpty ? nil : live.map(\.memoryMB).reduce(0, +)
        gpuUtilization = now.map(\.gpuUtilization).max() ?? 0
        gpuMemoryMB = now.map(\.gpuMemoryMB).max() ?? 0
    }

    /// Reads `JobID|JobIDRaw|Total|Max` rows from `sacct` and `JobID|Total|Max` rows from `sstat`.
    /// An array task has two IDs: `squeue` gives the raw one and `sacct` its `123_4` form, so the
    /// result is findable by either. `sstat` also complains about a job with no steps yet, so
    /// anything without a `|` is only an error if the command failed.
    static func parse(steps: [String], live: [String]) -> [String: JobUsage] {
        var rawIDs: [String: String] = [:]
        var readings: [String: [String: Reading]] = [:]
        for row in steps {
            let fields = row.components(separatedBy: "|")
            guard fields.count == 4 else { continue }
            let (raw, step) = split(fields[1])
            rawIDs[split(fields[0]).job] = raw
            rawIDs[raw] = raw
            guard let step, let reading = Reading(total: fields[2], peak: fields[3], isLive: false) else { continue }
            readings[raw, default: [:]][step] = reading
        }
        for row in live {
            let fields = row.components(separatedBy: "|")
            guard fields.count == 3 else { continue }
            let (job, step) = split(fields[0])
            guard let step, let reading = Reading(total: fields[1], peak: fields[2], isLive: true) else { continue }
            let raw = rawIDs[job] ?? job
            rawIDs[job] = raw
            readings[raw, default: [:]][step] = reading
        }
        var usage: [String: JobUsage] = [:]
        for (id, raw) in rawIDs {
            guard let job = readings[raw] else { continue }
            usage[id] = JobUsage(readings: Array(job.values))
        }
        return usage
    }

    private static func split(_ id: String) -> (job: String, step: String?) {
        let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
        return (parts.first ?? id, parts.count == 2 ? parts[1] : nil)
    }
}
