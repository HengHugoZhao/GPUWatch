import Foundation

/// Anyone's jobs on UVA HPC right now, looked up by computing ID: are they using GPUs, and which.
public struct UserLookup: Sendable {
    public let id: String
    /// From `getent`. Nil for an ID the cluster doesn't know, and for one with no name on file.
    public let name: String?
    public let exists: Bool
    public let jobs: [SlurmJob]

    /// Running ones, and those still letting go of their GPUs.
    public var runningGPUJobs: [SlurmJob] {
        jobs.filter { ($0.phase == .running || $0.phase == .completing) && ($0.gpuCount ?? 0) > 0 }
    }

    public var pendingGPUJobs: [SlurmJob] {
        jobs.filter { $0.phase == .pending && ($0.gpuCount ?? 0) > 0 }
    }

    public var gpusNow: Int { runningGPUJobs.compactMap(\.gpuCount).reduce(0, +) }

    public var otherRunningCount: Int {
        jobs.filter { ($0.phase == .running || $0.phase == .completing) && ($0.gpuCount ?? 0) == 0 }.count
    }

    /// "2 × a6000, 2 × b200", most first. A job's type comes from its node, since one on `gpu`
    /// usually doesn't name a type, and from its request otherwise.
    public func gpuSummary(snapshot: HPCSnapshot?) -> String {
        var counts: [String: Int] = [:]
        for job in runningGPUJobs {
            counts[Self.type(of: job, snapshot: snapshot) ?? "GPU", default: 0] += job.gpuCount ?? 0
        }
        return counts
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { "\($0.value) × \($0.key)" }
            .joined(separator: ", ")
    }

    public static func type(of job: SlurmJob, snapshot: HPCSnapshot?) -> String? {
        if let type = snapshot?.gpuType(of: job) { return type }
        guard let summary = job.gpus, let range = summary.range(of: " × ") else { return nil }
        return String(summary[range.upperBound...])
    }

    public static func parse(_ text: String, id: String) throws -> UserLookup {
        let output = RemoteOutput(text)
        guard output.isComplete, let jobs = output.sections["JOBS"] else {
            throw FetchFailure(headline: "The connection dropped mid-update", detail: "The cluster's reply was incomplete.")
        }
        if let message = jobs.failureMessage {
            throw FetchFailure(headline: "squeue", detail: message)
        }
        let who = output.firstLine("WHO")?.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let exists = who?.first == id
        let name = exists && (who?.count ?? 0) == 2 && !(who?[1].isEmpty ?? true)
            ? who?[1].replacingOccurrences(of: "_", with: " ")
            : nil
        let dates = SlurmFormat.dateParser(zoneLines: output.sections["TZ"]?.lines ?? [])
        return UserLookup(
            id: id,
            name: name,
            exists: exists,
            jobs: jobs.lines.compactMap { SlurmJob.parse(squeueLine: $0, dates: dates) }
        )
    }
}
