import GPUWatchCore
import SwiftUI

struct HPCPage: View {
    let snapshot: HPCSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            MyJobsSection(snapshot: snapshot)
            GPUAvailabilitySection(snapshot: snapshot)
            StorageSection(storage: snapshot.storage, error: snapshot.storageError, errorSource: "hdquota")
            AllocationSection(snapshot: snapshot)
        }
    }
}

// MARK: - My jobs

private struct MyJobsSection: View {
    @Environment(AppModel.self) private var model
    let snapshot: HPCSnapshot

    /// Three rows with bars fit under the list's cap, and a fourth doesn't.
    private static let rowsThatFit = 3

    private var activeSummary: String {
        if snapshot.activeJobs.isEmpty { return "Nothing running or queued" }
        return "\(snapshot.runningCount) running · \(snapshot.pendingCount) pending"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "My jobs", detail: activeSummary)
                Spacer()
                if snapshot.activeJobs.count > Self.rowsThatFit {
                    Button(model.showsAllActiveJobs ? "Show fewer jobs" : "Show all jobs") {
                        model.showsAllActiveJobs.toggle()
                    }
                }
            }
            if let error = snapshot.activeJobsError {
                SectionError(message: "squeue failed: \(error)")
            }
            if let error = snapshot.finishedJobsError {
                SectionError(message: "sacct failed: \(error)")
            }
            if let error = snapshot.jobUsageError {
                SectionError(message: "Job usage may be incomplete. \(error)")
            }
            Panel {
                if !snapshot.activeJobs.isEmpty {
                    jobList(snapshot.activeJobs, isCapped: !model.showsAllActiveJobs)
                    Divider()
                }
                finishedHeader
                if model.showsFinishedJobs, !snapshot.finishedJobs.isEmpty {
                    Divider()
                    jobList(snapshot.finishedJobs)
                }
            }
            if let failure = model.jobHistory.failure {
                SectionError(message: "\(failure.headline): \(failure.detail)")
            }
            if let history = model.jobHistory.value {
                JobActivity(history: history)
                GPUHoursPanel(usage: history.gpuUsage, today: history.today, note: gpuHoursNote(history.gpuUsage))
            }
        }
    }

    private func jobList(_ jobs: [SlurmJob], isCapped: Bool = true) -> some View {
        CappedScroll(isCapped: isCapped) {
            ForEach(jobs) { job in
                if job.id != jobs.first?.id { Divider() }
                JobRow(job: job, usage: snapshot.jobUsage[job.id], gpuMemoryTotalMB: snapshot.gpuMemoryTotalMB(of: job), isExpanded: binding(for: job.id))
            }
        }
    }

    private func gpuHoursNote(_ usage: GPUUsage) -> String {
        let since = usage.firstStart.map { "Since \($0.formatted(.dateTime.month(.abbreviated).year())). " } ?? ""
        return "\(since)GPUs allocated × time, including jobs that failed or were cancelled."
    }

    private var finishedHeader: some View {
        Button {
            model.showsFinishedJobs.toggle()
        } label: {
            HStack(spacing: 8) {
                Chevron(isOpen: model.showsFinishedJobs)
                Text("Finished in the last \(RemoteScripts.finishedWindowDays) days")
                    .fontWeight(.medium)
                Text(finishedSummary)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(HoverRowStyle())
        .disabled(snapshot.finishedJobs.isEmpty)
    }

    /// "72 completed · 3 failed": failures are visible without opening the list.
    private var finishedSummary: String {
        if snapshot.finishedJobs.isEmpty { return "None" }
        var order: [String] = []
        var counts: [String: Int] = [:]
        for job in snapshot.finishedJobs {
            let label = job.phase.label.lowercased()
            if counts[label] == nil { order.append(label) }
            counts[label, default: 0] += 1
        }
        return order
            .sorted { counts[$0]! > counts[$1]! }
            .map { "\(counts[$0]!) \($0)" }
            .joined(separator: " · ")
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { model.expandedJobs.contains(id) },
            set: { isOpen in
                if isOpen { model.expandedJobs.insert(id) } else { model.expandedJobs.remove(id) }
            }
        )
    }
}

private struct JobRow: View {
    let job: SlurmJob
    let usage: JobUsage?
    let gpuMemoryTotalMB: Int?
    @Binding var isExpanded: Bool

    /// Lines the bars up under the job's status, past the chevron.
    private static let usageInset: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Chevron(isOpen: isExpanded)
                            .padding(.top, 3)
                        job.phase.status
                            .frame(width: 112, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.name.isEmpty ? "(unnamed)" : job.name)
                                .fontWeight(.medium)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(resourceLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 12)
                        JobTiming(job: job)
                            .frame(width: 260, alignment: .trailing)
                    }
                    if let usage {
                        JobUsageStrip(job: job, usage: usage, gpuMemoryTotalMB: gpuMemoryTotalMB)
                            .padding(.leading, Self.usageInset)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .buttonStyle(HoverRowStyle())
            if isExpanded {
                JobDetails(job: job)
                    .padding(.leading, 36)
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
                    .padding(.top, 2)
            }
        }
    }

    private var resourceLine: String {
        var parts = [job.id, job.partition]
        if let gpus = job.gpus { parts.append(gpus) }
        if let cpus = job.cpus { parts.append("\(cpus) CPU\(cpus == 1 ? "" : "s")") }
        if job.phase != .pending, let nodes = job.nodesOrReason { parts.append(nodes) }
        return parts.joined(separator: " · ")
    }
}

/// What a job actually used. Four fixed columns, so they line up from row to row even when a
/// CPU-only job leaves two empty.
private struct JobUsageStrip: View {
    let job: SlurmJob
    let usage: JobUsage
    let gpuMemoryTotalMB: Int?

    private static let spacing: CGFloat = 16

    private var isRunning: Bool { job.phase.isActive }

    var body: some View {
        HStack(alignment: .top, spacing: Self.spacing) {
            cpu
            memory
            if job.gpuCount != nil {
                gpu
                gpuMemory
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
        }
    }

    private var cpu: UsageCell {
        let fraction = usage.cpuFraction(cpus: job.cpus, elapsedSeconds: job.elapsedSeconds)
        let time = Format.duration(Int(usage.cpuSeconds))
        return UsageCell(
            label: "CPU",
            value: fraction.map(Format.percent) ?? "–",
            fraction: fraction,
            explanation: "\(time) of CPU time \(isRunning ? "so far" : "in total"), out of what its \(job.cpus ?? 0) CPUs could have done."
        )
    }

    private var memory: UsageCell {
        let peak = Format.memory(mb: usage.peakMemoryMB)
        let (label, used, explanation): (String, Int, String)
        if isRunning, let current = usage.currentMemoryMB {
            (label, used, explanation) = ("RAM now", current, "Peak so far: \(peak).")
        } else {
            (label, used, explanation) = ("RAM peak", usage.peakMemoryMB, "The most it held at once.")
        }
        guard let total = job.allocatedMemoryMB, total > 0 else {
            return UsageCell(label: label, value: Format.memory(mb: used), fraction: nil, explanation: explanation)
        }
        return UsageCell(
            label: label,
            value: Format.memoryPair(usedMB: used, totalMB: total),
            fraction: Double(used) / Double(total),
            explanation: explanation
        )
    }

    private var noGPUReading: UsageCell {
        UsageCell(
            label: "GPU",
            value: "No reading",
            fraction: nil,
            explanation: "Slurm reported 0 for both GPU numbers, which can mean the job never used its GPU or that no reading was taken."
        )
    }

    private var gpu: UsageCell {
        guard let fraction = usage.gpuFraction(gpus: job.gpuCount) else { return noGPUReading }
        return UsageCell(
            label: "GPU",
            value: Format.percent(fraction),
            fraction: fraction,
            explanation: "Per GPU, from Slurm's one figure for the job. Slurm doesn't say whether it's a peak or an average, so treat it as a rough guide."
        )
    }

    private var gpuMemory: UsageCell {
        guard usage.hasGPUReading else {
            return UsageCell(label: "GPU memory", value: "–", fraction: nil, explanation: noGPUReading.explanation)
        }
        let gpus = job.gpuCount ?? 1
        let each = gpus > 1 ? ", about \(Format.memory(mb: usage.gpuMemoryMB / gpus)) each" : ""
        let explanation = "Across \(gpus == 1 ? "1 GPU" : "\(gpus) GPUs")\(each). This can include memory PyTorch is holding on to after freeing it."
        guard let total = gpuMemoryTotalMB else {
            return UsageCell(
                label: "GPU memory",
                value: Format.memory(mb: usage.gpuMemoryMB),
                fraction: nil,
                explanation: "\(explanation) No bar because the app doesn't know how much this job's GPUs hold."
            )
        }
        return UsageCell(
            label: "GPU memory",
            value: Format.memoryPair(usedMB: usage.gpuMemoryMB, totalMB: total),
            fraction: Double(usage.gpuMemoryMB) / Double(total),
            explanation: "\(explanation) The total comes from a table in the app for this GPU type, not from Slurm."
        )
    }
}

/// A job's use of one resource, in a row of these.
struct UsageCell: View {
    let label: String
    let value: String
    let fraction: Double?
    let explanation: String

    var body: some View {
        VStack(spacing: 3) {
            GlanceRow(label: label, value: value)
            if let fraction {
                Meter(fraction: fraction, height: 5)
            }
        }
        .frame(maxWidth: .infinity)
        .help(explanation)
    }
}

/// The right side of a job row: progress when running, the wait when queued, the outcome when done.
private struct JobTiming: View {
    let job: SlurmJob

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            switch job.phase {
            case .pending:
                Text(job.pendingExplanation ?? "Waiting")
                    .font(.callout)
                    .lineLimit(1)
                    .help(job.nodesOrReason ?? "")
                Text(startEstimate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .running, .completing, .suspended:
                Text(runningLine)
                    .font(.callout)
                    .monospacedDigit()
                    .lineLimit(1)
                if let elapsed = job.elapsedSeconds, let limit = job.limitSeconds, limit > 0 {
                    TimeMeter(fraction: Double(elapsed) / Double(limit))
                }
            default:
                Text(finishedLine)
                    .font(.callout)
                    .monospacedDigit()
                    .lineLimit(1)
                if let ended = job.ended {
                    Text("Ended \(Format.relative(ended, now: .now))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var startEstimate: String {
        guard let start = job.started else { return "No start estimate yet" }
        return "Estimated start \(Format.relative(start, now: .now))"
    }

    private var runningLine: String {
        guard let elapsed = job.elapsedSeconds else { return "–" }
        var line = Format.duration(elapsed)
        if let limit = job.limitSeconds { line += " of \(Format.duration(limit))" }
        if let ended = job.ended { line += " · ends \(Format.relative(ended, now: .now))" }
        return line
    }

    private var finishedLine: String {
        var parts: [String] = []
        if let exit = job.exitSummary { parts.append(exit) }
        if let elapsed = job.elapsedSeconds, elapsed > 0 {
            parts.append("Ran \(Format.duration(elapsed))")
        } else {
            parts.append("Never started")
        }
        return parts.joined(separator: " · ")
    }
}

private struct JobDetails: View {
    let job: SlurmJob

    private var rows: [(String, String)] {
        var rows: [(String, String)] = [("State", job.state)]
        if job.phase == .pending, let reason = job.nodesOrReason { rows.append(("Slurm reason", reason)) }
        if let submitted = job.submitted { rows.append(("Submitted", Format.absolute(submitted))) }
        if let started = job.started {
            rows.append((job.phase == .pending ? "Estimated start" : "Started", Format.absolute(started)))
        }
        if let ended = job.ended {
            rows.append((job.phase.isActive ? "Time limit ends" : "Ended", Format.absolute(ended)))
        }
        if let memory = job.memory { rows.append(("Memory", memory)) }
        if let account = job.account { rows.append(("Account", account)) }
        if let exitCode = job.exitCode { rows.append(("Exit code", exitCode)) }
        if let workDir = job.workDir { rows.append(("Working directory", workDir)) }
        if let path = job.stdoutPath { rows.append(("Output log", path)) }
        return rows
    }

    var body: some View {
        DetailGrid(rows: rows)
    }
}

// MARK: - GPU availability

private struct GPUAvailabilitySection: View {
    @Environment(AppModel.self) private var model
    let snapshot: HPCSnapshot

    var body: some View {
        let totals = snapshot.totals
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "GPU availability", detail: nil)
                Spacer()
                Button(allNodesShown ? "Hide all nodes" : "Show all nodes") {
                    model.expandedGPUTypes = allNodesShown ? [] : Set(snapshot.gpuTypes.map(\.id))
                }
                .disabled(snapshot.gpuTypes.isEmpty)
            }
            if let error = snapshot.nodesError {
                SectionError(message: "scontrol failed: \(error)")
            }
            HeadlineRow(hero: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(totals.ready)")
                            .font(.system(size: 40, weight: .semibold))
                        Text("of \(totals.total) GPUs ready now")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(totals.backfill) backfill · \(totals.stranded) stranded · \(totals.inUse) in use · \(totals.offline) offline")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }, side: cpuMemory)
            Legend()
            Panel {
                TypeHeaderRow()
                ForEach(snapshot.gpuTypes) { type in
                    Divider()
                    TypeRow(type: type, isExpanded: binding(for: type.id))
                }
            }
        }
    }

    private var allNodesShown: Bool {
        !snapshot.gpuTypes.isEmpty && snapshot.gpuTypes.allSatisfy { model.expandedGPUTypes.contains($0.id) }
    }

    private var cpuMemory: UsageMeter? {
        guard snapshot.memoryTotalMB > 0 else { return nil }
        return UsageMeter(
            title: "CPU memory on GPU nodes",
            usedMB: snapshot.memoryAllocatedMB,
            totalMB: snapshot.memoryTotalMB,
            usedWord: "allocated",
            remainderWord: "free",
            explanation: "Memory Slurm has reserved for running jobs, which is what decides whether a new job fits. Jobs may actually be using less."
        )
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { model.expandedGPUTypes.contains(id) },
            set: { isOpen in
                if isOpen { model.expandedGPUTypes.insert(id) } else { model.expandedGPUTypes.remove(id) }
            }
        )
    }
}

private struct Legend: View {
    private var items: [(color: Color, name: String)] {
        [
            (Theme.good, "Ready"),
            (Theme.warning, "Backfill"),
            (Theme.stranded, "Stranded"),
            (Theme.inUse, "In use"),
            (Theme.barTrack, "Offline"),
        ]
    }

    var body: some View {
        HStack(spacing: 16) {
            ForEach(items, id: \.name) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Swatch(color: item.color)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    Text(item.name).fontWeight(.medium)
                }
                .font(.caption)
            }
        }
    }
}

private enum TypeColumn {
    static let name: CGFloat = 104
    static let partition: CGFloat = 70
    static let count: CGFloat = 50
    static let inUse: CGFloat = 64
    static let memory: CGFloat = 94
    static let spacing: CGFloat = 12
}

private struct TypeHeaderRow: View {
    var body: some View {
        HStack(spacing: TypeColumn.spacing) {
            Text("GPU type").frame(width: TypeColumn.name + 20, alignment: .leading)
            Text("Partition").frame(width: TypeColumn.partition, alignment: .leading)
            Text("Ready").frame(width: TypeColumn.count, alignment: .trailing)
            Text("Backfill").frame(width: TypeColumn.count, alignment: .trailing)
            Text("Stranded").frame(width: TypeColumn.count, alignment: .trailing)
            Text("Share of pool").frame(maxWidth: .infinity, alignment: .leading)
            Text("GPUs in use").frame(width: TypeColumn.inUse, alignment: .trailing)
            Text("CPU memory used").frame(width: TypeColumn.memory, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct CountCell: View {
    let value: Int

    var body: some View {
        Text("\(value)")
            .fontWeight(value > 0 ? .semibold : .regular)
            .foregroundStyle(value > 0 ? .primary : .tertiary)
            .monospacedDigit()
            .frame(width: TypeColumn.count, alignment: .trailing)
    }
}

private struct TypeRow: View {
    let type: GPUTypeSummary
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: TypeColumn.spacing) {
                    HStack(spacing: 8) {
                        Chevron(isOpen: isExpanded)
                        Text(type.type).fontWeight(.medium).lineLimit(1)
                    }
                    .frame(width: TypeColumn.name + 20, alignment: .leading)
                    Text(type.partitions.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: TypeColumn.partition, alignment: .leading)
                    CountCell(value: type.counts.ready)
                    CountCell(value: type.counts.backfill)
                    CountCell(value: type.counts.stranded)
                    GPUBar(counts: type.counts)
                        .frame(maxWidth: .infinity)
                    Text("\(type.counts.inUse) / \(type.counts.total)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: TypeColumn.inUse, alignment: .trailing)
                    Text(Format.memoryPair(usedMB: type.memoryAllocatedMB, totalMB: type.memoryTotalMB))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: TypeColumn.memory, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .buttonStyle(HoverRowStyle())
            if isExpanded {
                NodeTable(nodes: type.nodes)
            }
        }
    }
}

/// Fixed widths, so bars line up across node tables when several GPU types are open.
private enum NodeColumn {
    static let name: CGFloat = 84
    static let state: CGFloat = 76
    static let gpus: CGFloat = 56
    static let cpus: CGFloat = 84
    static let memoryBarMin: CGFloat = 80
    static let memoryBarMax: CGFloat = 150
    static let memoryUsed: CGFloat = 88
    static let memoryFree: CGFloat = 78
    static let spacing: CGFloat = 16
}

private struct NodeTable: View {
    let nodes: [HPCNode]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: NodeColumn.spacing) {
                Text("Node").frame(width: NodeColumn.name, alignment: .leading)
                Text("State").frame(width: NodeColumn.state, alignment: .leading)
                Text("GPUs free").frame(width: NodeColumn.gpus, alignment: .trailing)
                Text("CPUs free").frame(width: NodeColumn.cpus, alignment: .trailing)
                // Sits over the bar and spills into the empty column beside it.
                Text("CPU memory allocated")
                    .fixedSize()
                    .frame(minWidth: NodeColumn.memoryBarMin, maxWidth: NodeColumn.memoryBarMax, alignment: .leading)
                    .layoutPriority(1)
                Color.clear.frame(width: NodeColumn.memoryUsed, height: 1)
                Text("Memory free").frame(width: NodeColumn.memoryFree, alignment: .trailing)
                Text("Note").frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.secondary)
            ForEach(nodes) { node in
                NodeRow(node: node)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .lineLimit(1)
        .padding(.leading, 34)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
    }
}

private struct NodeRow: View {
    let node: HPCNode

    var body: some View {
        HStack(spacing: NodeColumn.spacing) {
            Text(node.name)
                .textSelection(.enabled)
                .frame(width: NodeColumn.name, alignment: .leading)
            Text(node.stateLabel ?? "Healthy")
                .foregroundStyle(node.stateLabel == nil ? .tertiary : .primary)
                .frame(width: NodeColumn.state, alignment: .leading)
            Text("\(node.gpuFree) / \(node.gpuTotal)")
                .frame(width: NodeColumn.gpus, alignment: .trailing)
            limited(node.cpuLimited, help: "Not enough free CPUs for this node's free GPUs") {
                Text("\(node.cpuFree) / \(node.cpuTotal)")
            }
            .frame(width: NodeColumn.cpus, alignment: .trailing)
            Meter(fraction: node.memoryFraction)
                .frame(minWidth: NodeColumn.memoryBarMin, maxWidth: NodeColumn.memoryBarMax)
                .layoutPriority(1)
                .help("\(Format.memory(mb: node.memoryAllocatedMB)) of \(Format.memory(mb: node.memoryTotalMB)) allocated to jobs")
            Text(Format.memoryPair(usedMB: node.memoryAllocatedMB, totalMB: node.memoryTotalMB))
                .frame(width: NodeColumn.memoryUsed, alignment: .trailing)
            limited(node.memoryLimited, help: "Not enough free memory for this node's free GPUs") {
                Text(Format.memory(mb: node.memoryFreeMB))
            }
            .frame(width: NodeColumn.memoryFree, alignment: .trailing)
            Text(node.reason ?? "")
                .foregroundStyle(.secondary)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(node.reason ?? "")
        }
        // A down node's "free" resources can't take a job, so they shouldn't read as available.
        .foregroundStyle(node.isAvailable ? .primary : .tertiary)
    }

    @ViewBuilder
    private func limited<Content: View>(_ isLimited: Bool, help: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 4) {
            if isLimited {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.serious)
                    .help(help)
                    .accessibilityLabel(help)
            }
            content()
        }
    }
}

// MARK: - Lab allocation

private struct AllocationSection: View {
    let snapshot: HPCSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Lab allocation", detail: RemoteScripts.labAccount)
            MyUsage(snapshot: snapshot)
            if let error = snapshot.allocationError {
                SectionError(message: "mam-list-allocations: \(error)")
            }
            if let allocation = snapshot.allocation {
                GrantTable(allocation: allocation)
                Text("Grants update when a job ends, so running jobs aren't counted yet. Failed, cancelled and out-of-memory jobs are free.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Grants that can still be spent, with the rest folded away.
private struct GrantTable: View {
    @Environment(AppModel.self) private var model
    let allocation: LabAllocation

    var body: some View {
        Panel {
            GrantHeaderRow()
            ForEach(allocation.activeGrants) { grant in
                Divider()
                GrantRow(grant: grant)
            }
            let inactive = allocation.inactiveGrants
            if !inactive.isEmpty {
                Divider()
                inactiveHeader(inactive)
                if model.showsInactiveGrants {
                    ForEach(inactive) { grant in
                        Divider()
                        GrantRow(grant: grant)
                    }
                }
            }
        }
    }

    private func inactiveHeader(_ grants: [AllocationGrant]) -> some View {
        Button {
            model.showsInactiveGrants.toggle()
        } label: {
            HStack(spacing: 8) {
                Chevron(isOpen: model.showsInactiveGrants)
                Text(grants.allSatisfy { $0.phase(now: .now) == .expired } ? "Expired grants" : "Inactive grants")
                    .fontWeight(.medium)
                Text("\(grants.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(HoverRowStyle())
    }
}

/// The user's own use, which the lab-wide grants can't show.
private struct MyUsage: View {
    @Environment(AppModel.self) private var model
    let snapshot: HPCSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let failure = model.charges.failure {
                SectionError(message: "\(failure.headline): \(failure.detail)")
            }
            MyShare(snapshot: snapshot)
            if let charges = model.charges.value, charges.total > 0 {
                ChargesHistory(charges: charges)
            }
        }
    }
}

/// How much of what the lab has used on each grant was the user. Grants nobody has used are
/// left out, since there's nothing to take a share of.
private struct MyShare: View {
    @Environment(AppModel.self) private var model
    let snapshot: HPCSnapshot

    private static let nameWidth: CGFloat = 130
    private static let percentWidth: CGFloat = 44
    private static let amountWidth: CGFloat = 170

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("My share of the SUs \(RemoteScripts.labAccount) has used")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(runningLine)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .monospacedDigit()
                .lineLimit(1)
                ForEach(rows, id: \.grant.id) { row in
                    shareRow(grant: row.grant, mine: row.mine)
                }
            }
            .padding(14)
        }
    }

    private var rows: [(grant: AllocationGrant, mine: Int)] {
        guard let grants = snapshot.allocation?.grants, let charges = model.jobHistory.value?.charges(on: grants) else { return [] }
        return grants.compactMap { grant in
            guard grant.used > 0, let mine = charges[grant.id] else { return nil }
            return (grant, mine)
        }
    }

    private func shareRow(grant: AllocationGrant, mine: Int) -> some View {
        let fraction = Double(mine) / Double(grant.used)
        return HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(grant.description.isEmpty ? "(unnamed)" : grant.description)
                    .fontWeight(.medium)
                    .truncationMode(.middle)
                if !grant.isActive {
                    Text("expired")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.nameWidth, alignment: .leading)
            Meter(fraction: fraction, height: 10)
                .frame(maxWidth: .infinity)
                .help("\(Format.credits(mine)) of the \(Format.credits(grant.used)) SUs used on this grant")
            Text(Format.percent(fraction))
                .fontWeight(.medium)
                .frame(width: Self.percentWidth, alignment: .trailing)
            Text("\(Format.credits(mine)) of \(Format.credits(grant.used)) SUs")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: Self.amountWidth, alignment: .trailing)
        }
        .monospacedDigit()
        .lineLimit(1)
    }

    /// Kept out of the shares, because none of this is charged until the job ends.
    private var runningLine: String {
        let (count, rate) = (snapshot.runningCount, snapshot.runningCreditsPerHour)
        guard rate > 0 else { return "" }
        let soFar = Format.credits(Int(snapshot.runningCreditsSoFar.rounded()))
        let jobs = count == 1 ? "1 running job, charged when it ends" : "\(count) running jobs, charged when they end"
        return "\(jobs): \(Format.creditRate(rate)) SUs an hour, about \(soFar) so far"
    }
}

private enum GrantColumn {
    static let status: CGFloat = 72
    static let grantMin: CGFloat = 150
    static let used: CGFloat = 150
    static let remaining: CGFloat = 104
    static let barMin: CGFloat = 80
    static let barMax: CGFloat = 150
    static let percent: CGFloat = 44
    static let spacing: CGFloat = 12
}

private struct GrantHeaderRow: View {
    var body: some View {
        HStack(spacing: GrantColumn.spacing) {
            Text("Status").frame(width: GrantColumn.status, alignment: .leading)
            Text("Grant").frame(minWidth: GrantColumn.grantMin, maxWidth: .infinity, alignment: .leading)
            Text("Used / allocated").frame(width: GrantColumn.used, alignment: .trailing)
            Text("Remaining").frame(width: GrantColumn.remaining, alignment: .trailing)
            Text("Share used")
                .frame(minWidth: GrantColumn.barMin + GrantColumn.percent + 6, maxWidth: GrantColumn.barMax + GrantColumn.percent + 6, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct GrantRow: View {
    let grant: AllocationGrant

    var body: some View {
        HStack(spacing: GrantColumn.spacing) {
            grant.phase(now: .now).status
                .frame(width: GrantColumn.status, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(grant.description.isEmpty ? "(unnamed)" : grant.description)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(period)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: GrantColumn.grantMin, maxWidth: .infinity, alignment: .leading)
            // Shrinks rather than truncates: a clipped number would read as a different number.
            Text("\(Format.credits(grant.used)) / \(Format.credits(grant.allocated))")
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: GrantColumn.used, alignment: .trailing)
            // What an inactive grant has left can't be spent, so it isn't shown as remaining.
            Text(grant.isActive ? Format.credits(grant.remaining) : "–")
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: GrantColumn.remaining, alignment: .trailing)
                .help(grant.isActive ? "" : "\(Format.credits(grant.remaining)) SUs went unused")
            HStack(spacing: 6) {
                Meter(fraction: grant.usedFraction)
                    .frame(minWidth: GrantColumn.barMin, maxWidth: GrantColumn.barMax)
                    .opacity(grant.isActive ? 1 : 0.4)
                    .help("\(Format.credits(grant.used)) of \(Format.credits(grant.allocated)) SUs used")
                Text(Format.percent(grant.usedFraction))
                    .font(.caption)
                    .lineLimit(1)
                    .frame(width: GrantColumn.percent, alignment: .trailing)
            }
        }
        .monospacedDigit()
        .foregroundStyle(grant.isActive ? .primary : .tertiary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var period: String {
        let start = grant.starts.map(Format.day) ?? "Unknown start"
        let end = grant.ends.map(Format.day) ?? "no end date"
        return "\(start) – \(end)"
    }
}
