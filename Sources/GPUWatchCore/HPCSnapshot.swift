import Foundation

public struct HPCSnapshot: Sendable {
    /// Most recent finished jobs to keep; an array job can finish thousands of tasks.
    static let finishedLimit = 200

    public let me: String
    public let gpuTypes: [GPUTypeSummary]
    let gpuTypeByNode: [String: String]
    public let activeJobs: [SlurmJob]
    public let finishedJobs: [SlurmJob]
    /// By job ID, in whichever form `squeue` or `sacct` gave it.
    public let jobUsage: [String: JobUsage]
    public let allocation: LabAllocation?
    public let storage: [StorageUsage]
    /// A failed `sacct` should not hide a working `squeue`, so each part reports on its own.
    public let nodesError: String?
    public let activeJobsError: String?
    public let finishedJobsError: String?
    public let jobUsageError: String?
    public let allocationError: String?
    public let storageError: String?

    public var totals: GPUCounts { gpuTypes.map(\.counts).reduce(GPUCounts(), +) }
    public var memoryTotalMB: Int { gpuTypes.map(\.memoryTotalMB).reduce(0, +) }
    public var memoryAllocatedMB: Int { gpuTypes.map(\.memoryAllocatedMB).reduce(0, +) }
    public var runningJobs: [SlurmJob] { activeJobs.filter { $0.phase == .running || $0.phase == .completing } }
    public var runningCount: Int { runningJobs.count }
    public var runningCreditsPerHour: Double { runningJobs.compactMap(\.creditsPerHour).reduce(0, +) }
    public var runningCreditsSoFar: Double { runningJobs.compactMap(\.creditsSoFar).reduce(0, +) }
    public var pendingCount: Int { activeJobs.filter { $0.phase == .pending }.count }

    /// Going by its node, like `gpuMemoryTotalMB`. Nil across several nodes or off the GPU nodes.
    public func gpuType(of job: SlurmJob) -> String? {
        job.nodesOrReason.flatMap { gpuTypeByNode[$0] }
    }

    /// All the memory on a job's GPUs, going by its node, since a job on `gpu` usually doesn't name
    /// a type. Nil across several nodes, whose list Slurm compresses, and for a type not in the table.
    public func gpuMemoryTotalMB(of job: SlurmJob) -> Int? {
        guard let node = job.nodesOrReason, let gpus = job.gpuCount,
              let type = gpuTypeByNode[node], let each = HPCNode.gpuMemoryGB[type] else { return nil }
        return gpus * each * 1024
    }

    public static func parse(_ text: String) throws -> HPCSnapshot {
        let output = RemoteOutput(text)
        guard output.isComplete else {
            throw FetchFailure(headline: "The connection dropped mid-update", detail: "The cluster's reply was incomplete.")
        }
        let dates = SlurmFormat.dateParser(zoneLines: output.sections["TZ"]?.lines ?? [])

        let nodeSection = output.sections["NODES"]
        let nodes = nodeSection?.exitCode == 0 ? (nodeSection?.lines ?? []).compactMap(HPCNode.init(scontrolLine:)) : []

        let activeSection = output.sections["ACTIVE"]
        let active = activeSection?.exitCode == 0
            ? (activeSection?.lines ?? []).compactMap { SlurmJob.parse(squeueLine: $0, dates: dates) }
            : []

        let finishedSection = output.sections["FINISHED"]
        let finished = finishedSection?.exitCode == 0
            ? (finishedSection?.lines ?? []).compactMap { SlurmJob.parse(sacctLine: $0, dates: dates) }
            : []

        let (stepRows, stepsError) = rowsAndFailure(output.sections["STEPS"])
        let (liveRows, liveError) = rowsAndFailure(output.sections["LIVE"])

        // MAM answers an account it doesn't know with no output and exit 0.
        let allocationSection = output.sections["ALLOCATION"]
        let account = RemoteScripts.labAccount
        let grants = allocationSection?.exitCode == 0
            ? (allocationSection?.lines ?? []).compactMap(AllocationGrant.init(csvLine:))
            : []

        let me = output.firstLine("ME") ?? ""
        let storage = StorageUsage.fromQuotaReport(output.sections["STORAGE"], targets: RemoteScripts.hpcStorage(for: me))

        let activeIDs = Set(active.map(\.id))
        return HPCSnapshot(
            me: me,
            gpuTypes: GPUTypeSummary.group(nodes),
            gpuTypeByNode: Dictionary(uniqueKeysWithValues: nodes.map { ($0.name, $0.gpuType) }),
            activeJobs: active.sorted(by: activeOrder),
            finishedJobs: Array(
                finished.filter { !$0.phase.isActive && !activeIDs.contains($0.id) }
                    .sorted { ($0.ended ?? .distantPast) > ($1.ended ?? .distantPast) }
                    .prefix(finishedLimit)
            ),
            jobUsage: JobUsage.parse(steps: stepRows, live: liveRows),
            allocation: grants.isEmpty ? nil : LabAllocation(account: account, grants: grants),
            storage: storage.usage,
            nodesError: nodeSection?.failureMessage,
            activeJobsError: activeSection?.failureMessage,
            finishedJobsError: finishedSection?.failureMessage,
            jobUsageError: stepsError.map { "sacct: \($0)" } ?? liveError.map { "sstat: \($0)" },
            allocationError: allocationSection?.failureMessage ?? (grants.isEmpty ? "No allocations listed for \(account)" : nil),
            storageError: storage.error
        )
    }

    /// A query stopped partway can still have rows worth showing, and they shouldn't end up in its error.
    private static func rowsAndFailure(_ section: RemoteOutput.Section?) -> (rows: [String], failure: String?) {
        guard var section else { return ([], nil) }
        let rows = section.lines.filter { $0.contains("|") }
        section.lines.removeAll { $0.contains("|") }
        return (rows, section.failureMessage)
    }

    /// Running jobs first, newest start on top; then the queue in submission order.
    private static func activeOrder(_ a: SlurmJob, _ b: SlurmJob) -> Bool {
        let (aPending, bPending) = (a.phase == .pending, b.phase == .pending)
        if aPending != bPending { return bPending }
        if aPending { return (a.submitted ?? .distantPast) < (b.submitted ?? .distantPast) }
        return (a.started ?? .distantPast) > (b.started ?? .distantPast)
    }
}
