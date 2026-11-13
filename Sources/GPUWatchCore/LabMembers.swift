import Foundation

/// One person on the lab's account and what they hold on the cluster right now.
public struct LabMember: Identifiable, Sendable {
    public let id: String
    /// From `getent`. Nil when the account has no name on file.
    public let name: String?
    public let jobs: [SlurmJob]

    public var runningJobs: [SlurmJob] { jobs.filter { $0.phase == .running || $0.phase == .completing } }
    public var pendingJobs: [SlurmJob] { jobs.filter { $0.phase == .pending } }
    public var gpus: Int { runningJobs.compactMap(\.gpuCount).reduce(0, +) }
    public var cpus: Int { runningJobs.compactMap(\.cpus).reduce(0, +) }
    public var memoryMB: Int { runningJobs.compactMap(\.allocatedMemoryMB).reduce(0, +) }
    public var isIdle: Bool { jobs.isEmpty }
}

/// Everyone on the lab's account with their running and queued jobs, busiest first.
public struct LabMembers: Sendable {
    public let account: String
    public let members: [LabMember]

    public var gpus: Int { members.map(\.gpus).reduce(0, +) }
    public var activeCount: Int { members.filter { !$0.runningJobs.isEmpty }.count }

    public static func parse(_ text: String, account: String) throws -> LabMembers {
        let output = RemoteOutput(text)
        guard output.isComplete, let jobSection = output.sections["LABJOBS"] else {
            throw FetchFailure(headline: "The connection dropped mid-update", detail: "The cluster's reply was incomplete.")
        }
        if let message = jobSection.failureMessage {
            throw FetchFailure(headline: "squeue", detail: message)
        }
        let dates = SlurmFormat.dateParser(zoneLines: output.sections["TZ"]?.lines ?? [])

        var jobsByUser: [String: [SlurmJob]] = [:]
        for line in jobSection.lines {
            // The user comes first, ahead of the fields `SlurmJob` reads.
            guard let bar = line.firstIndex(of: "|") else { continue }
            let user = String(line[..<bar]).trimmingCharacters(in: .whitespaces)
            guard !user.isEmpty, let job = SlurmJob.parse(squeueLine: String(line[line.index(after: bar)...]), dates: dates) else { continue }
            jobsByUser[user, default: []].append(job)
        }

        var names: [String: String] = [:]
        for line in output.sections["NAMES"]?.lines ?? [] {
            let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty else { continue }
            names[fields[0]] = fields[1].replacingOccurrences(of: "_", with: " ")
        }

        // A failed member list still leaves everyone who has a job.
        let listed = output.sections["MEMBERS"].flatMap { $0.exitCode == 0 ? $0.lines : nil } ?? []
        let ids = Set(listed.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }).union(jobsByUser.keys)
        let members = ids.map { LabMember(id: $0, name: names[$0], jobs: jobsByUser[$0] ?? []) }
            .sorted { a, b in
                if a.gpus != b.gpus { return a.gpus > b.gpus }
                if a.cpus != b.cpus { return a.cpus > b.cpus }
                if a.jobs.count != b.jobs.count { return a.jobs.count > b.jobs.count }
                return (a.name ?? a.id) < (b.name ?? b.id)
            }
        return LabMembers(account: account, members: members)
    }
}
