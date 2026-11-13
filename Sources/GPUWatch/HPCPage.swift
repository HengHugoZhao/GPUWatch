import GPUWatchCore
import SwiftUI

struct HPCPage: View {
    let snapshot: HPCSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            MyJobsSection(snapshot: snapshot)
            UserLookupSection(snapshot: snapshot)
            GPUAvailabilitySection(snapshot: snapshot)
            StorageSection(storage: snapshot.storage, error: snapshot.storageError, errorSource: "hdquota")
            AllocationSection(snapshot: snapshot)
            LabMembersSection(snapshot: snapshot)
        }
    }
}

// MARK: - My jobs

private struct MyJobsSection: View {
    @Environment(AppModel.self) private var model
    let snapshot: HPCSnapshot

    /// Three rows with bars fit under the list's cap, and a fourth doesn't.
    private static let rowsThatFit = 3
    /// About three running-job cards, so a cut-off fourth shows there's more.
    private static let cardsHeight: CGFloat = 400

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
            if !snapshot.activeJobs.isEmpty {
                CappedScroll(isCapped: !model.showsAllActiveJobs, maxHeight: Self.cardsHeight) {
                    VStack(spacing: 8) {
                        ForEach(snapshot.activeJobs) { job in
                            JobRow(job: job, usage: snapshot.jobUsage[job.id], gpuMemoryTotalMB: snapshot.gpuMemoryTotalMB(of: job), isCard: true, isExpanded: binding(for: job.id))
                                .surface()
                        }
                    }
                }
            }
            Panel {
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
                JobRow(job: job, usage: snapshot.jobUsage[job.id], gpuMemoryTotalMB: snapshot.gpuMemoryTotalMB(of: job), isCard: false, isExpanded: binding(for: job.id))
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
    /// On its own card, running or queued. Otherwise a row in the finished list, which names its outcome.
    let isCard: Bool
    @Binding var isExpanded: Bool

    /// Past the chevron and the dot, so the bars start under the name.
    private static let usageInset: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Chevron(isOpen: isExpanded)
                            .padding(.top, 3)
                        StatusDot(status: job.phase.status)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(job.name.isEmpty ? "(unnamed)" : job.name)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                // A finished job's outcome is the point of the row, so it's spelled out.
                                if !isCard {
                                    Text(job.phase.label)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
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
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, isCard ? 12 : 10)
            }
            .buttonStyle(HoverRowStyle())
            if isExpanded {
                JobDetails(job: job)
                    .padding(.leading, 60)
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

    private static let spacing: CGFloat = 20

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
                explanation: "\(explanation) The bar stays empty because the app doesn't know how much this job's GPUs hold."
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

/// A job's use of one resource, in a row of these: one line with what it is and the amount,
/// and a thin bar under it.
struct UsageCell: View {
    let label: String
    let value: String
    let fraction: Double?
    let explanation: String

    private var percent: String? {
        fraction.map { "\(Int((min(max($0, 0), 1) * 100).rounded()))%" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value)
                    .fontWeight(.medium)
                // A percentage value already says this, so only an amount gets its share beside it.
                if let percent, !value.hasSuffix("%") {
                    Text(percent)
                        .foregroundStyle(Theme.accent)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            Meter(fraction: fraction ?? 0, height: 4)
                .opacity(fraction == nil ? 0.5 : 1)
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(explanation)
        .accessibilityElement(children: .combine)
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

    private static let cardMinimumWidth: CGFloat = 200

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
            HStack(alignment: .top, spacing: 12) {
                StatTile(
                    title: "Ready now",
                    value: "\(totals.ready) of \(totals.total)",
                    caption: "\(totals.backfill) backfill · \(totals.stranded) stranded"
                ) {
                    GPUBar(counts: totals)
                }
                .help("GPUs a new job could start on right away. Backfill: free, but held for a queued job. Stranded: free, but the node has no CPU or memory left.")
                StatTile(
                    title: "In use",
                    value: "\(totals.inUse)",
                    caption: "\(totals.offline) more offline"
                ) {
                    Meter(fraction: totals.total > 0 ? Double(totals.inUse) / Double(totals.total) : 0)
                }
                if snapshot.memoryTotalMB > 0 {
                    StatTile(
                        title: "CPU memory on GPU nodes",
                        value: Format.memory(mb: snapshot.memoryAllocatedMB),
                        caption: "allocated of \(Format.memory(mb: snapshot.memoryTotalMB))"
                    ) {
                        Meter(fraction: Double(snapshot.memoryAllocatedMB) / Double(snapshot.memoryTotalMB))
                    }
                    .help("Memory Slurm has reserved for running jobs, which is what decides whether a new job fits. Jobs may actually be using less.")
                }
            }
            Legend()
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.cardMinimumWidth), spacing: 12, alignment: .top)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(snapshot.gpuTypes) { type in
                    GPUTypeCard(type: type, isExpanded: binding(for: type.id))
                }
            }
            // Opened types' nodes go under the grid, where a full-width table has room.
            ForEach(snapshot.gpuTypes.filter { model.expandedGPUTypes.contains($0.id) }) { type in
                NodePanel(type: type, isOpen: binding(for: type.id))
            }
        }
    }

    private var allNodesShown: Bool {
        !snapshot.gpuTypes.isEmpty && snapshot.gpuTypes.allSatisfy { model.expandedGPUTypes.contains($0.id) }
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

/// One GPU type at a glance: how many a new job could start on, the pool's split, what's in use.
/// Clicking it opens its nodes below the grid.
private struct GPUTypeCard: View {
    let type: GPUTypeSummary
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(type.type)
                        .font(.headline)
                        .lineLimit(1)
                    Text(type.partitions.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(type.counts.ready)")
                        .display(26)
                        .monospacedDigit()
                        .foregroundStyle(type.counts.ready > 0 ? Theme.good : .secondary)
                    Text("ready of \(type.counts.total)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                GPUBar(counts: type.counts)
                VStack(alignment: .leading, spacing: 3) {
                    Text(breakdown)
                    HStack {
                        Text("CPU memory")
                        Spacer(minLength: 4)
                        Text(Format.memoryPair(usedMB: type.memoryAllocatedMB, totalMB: type.memoryTotalMB))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .surface(isExpanded ? Theme.surfaceRaised : Theme.surface, border: isExpanded ? Theme.accent.opacity(0.7) : Theme.hairline)
        .help(isExpanded ? "Hide \(type.type) nodes" : "Show \(type.type) nodes")
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
    }

    /// Only the parts there are, so a fully used type reads "31 in use" rather than a row of zeros.
    private var breakdown: String {
        let counts = type.counts
        var parts = ["\(counts.inUse) in use"]
        if counts.backfill > 0 { parts.append("\(counts.backfill) backfill") }
        if counts.stranded > 0 { parts.append("\(counts.stranded) stranded") }
        if counts.offline > 0 { parts.append("\(counts.offline) offline") }
        return parts.joined(separator: " · ")
    }
}

/// Fixed widths, so columns line up across node panels when several GPU types are open.
private enum NodeColumn {
    static let name: CGFloat = 100
    static let state: CGFloat = 110
    static let gpus: CGFloat = 150
    static let cpus: CGFloat = 80
    static let memoryBarMin: CGFloat = 90
    static let memoryBarMax: CGFloat = 170
    static let memoryUsed: CGFloat = 96
    static let memoryFree: CGFloat = 78
    static let spacing: CGFloat = 16
}

private struct NodePanel: View {
    let type: GPUTypeSummary
    @Binding var isOpen: Bool

    var body: some View {
        Panel {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(type.type) nodes").font(.headline)
                Text("\(type.nodes.count) on \(type.partitions.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    isOpen = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide \(type.type) nodes")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            HStack(spacing: NodeColumn.spacing) {
                Text("Node").frame(width: NodeColumn.name, alignment: .leading)
                Text("State").frame(width: NodeColumn.state, alignment: .leading)
                Text("GPUs").frame(width: NodeColumn.gpus, alignment: .leading)
                Text("CPUs free").frame(width: NodeColumn.cpus, alignment: .trailing)
                Text("CPU memory allocated")
                    .fixedSize()
                    .frame(minWidth: NodeColumn.memoryBarMin, maxWidth: NodeColumn.memoryBarMax, alignment: .leading)
                    .layoutPriority(1)
                Color.clear.frame(width: NodeColumn.memoryUsed, height: 1)
                Text("Free").frame(width: NodeColumn.memoryFree, alignment: .trailing)
                Text("Note").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            ForEach(type.nodes) { node in
                Rectangle().fill(Theme.hairline).frame(height: 1)
                NodeRow(node: node)
            }
        }
    }
}

private struct NodeRow: View {
    let node: HPCNode

    var body: some View {
        HStack(spacing: NodeColumn.spacing) {
            Text(node.name)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(width: NodeColumn.name, alignment: .leading)
            state
                .frame(width: NodeColumn.state, alignment: .leading)
            HStack(spacing: 8) {
                GPUSquares(counts: node.counts)
                Text("\(node.gpuFree) free")
                    .foregroundStyle(.secondary)
            }
            .frame(width: NodeColumn.gpus, alignment: .leading)
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
        .font(.caption)
        .monospacedDigit()
        .lineLimit(1)
        // A down node's "free" resources can't take a job, so they shouldn't read as available.
        .foregroundStyle(node.isAvailable ? .primary : .tertiary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private var state: some View {
        let status: StatusLabel
        if !node.isAvailable {
            status = StatusLabel(symbol: "xmark.circle.fill", color: Theme.stranded, text: node.stateLabel ?? "Unavailable")
        } else if let label = node.stateLabel {
            status = StatusLabel(symbol: "clock.fill", color: Theme.warning, text: label)
        } else {
            status = StatusLabel(symbol: "checkmark.circle.fill", color: Theme.good, text: "Healthy")
        }
        return status
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

/// A node's GPUs one square each, coloured as in the legend, so a node's state reads at a glance.
private struct GPUSquares: View {
    let counts: GPUCounts

    var body: some View {
        let colors = Array(repeating: Theme.good, count: counts.ready)
            + Array(repeating: Theme.warning, count: counts.backfill)
            + Array(repeating: Theme.stranded, count: counts.stranded)
            + Array(repeating: Theme.inUse, count: counts.inUse)
            + Array(repeating: Theme.barTrack, count: counts.offline)
        HStack(spacing: 2) {
            ForEach(colors.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(colors[index])
                    .frame(width: 8, height: 10)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(counts.ready) ready, \(counts.backfill) backfill, \(counts.stranded) stranded, \(counts.inUse) in use, \(counts.offline) offline")
    }
}

// MARK: - Lab allocation

private struct AllocationSection: View {
    @Environment(AppModel.self) private var model
    let snapshot: HPCSnapshot

    private static let cardMinimumWidth: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Lab allocation", detail: RemoteScripts.labAccount)
            if let running = runningLine {
                Label(running, systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let error = snapshot.allocationError {
                SectionError(message: "mam-list-allocations: \(error)")
            }
            if let allocation = snapshot.allocation {
                let mine = myCharges(allocation.grants)
                grid(allocation.activeGrants, mine: mine)
                let inactive = allocation.inactiveGrants
                if !inactive.isEmpty {
                    Button {
                        model.showsInactiveGrants.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            Chevron(isOpen: model.showsInactiveGrants)
                            Text(inactive.allSatisfy { $0.phase(now: .now) == .expired } ? "Expired grants" : "Inactive grants")
                                .fontWeight(.medium)
                            Text("\(inactive.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if model.showsInactiveGrants {
                        grid(inactive, mine: mine)
                    }
                }
                Text("Grants update when a job ends, so running jobs aren't counted yet. Failed, cancelled and out-of-memory jobs are free.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func grid(_ grants: [AllocationGrant], mine: [Int: Int]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Self.cardMinimumWidth), spacing: 12, alignment: .top)],
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(grants) { grant in
                GrantCard(grant: grant, mine: grant.used > 0 ? mine[grant.id] : nil)
            }
        }
    }

    /// What the user was charged on each grant, from their own job history.
    private func myCharges(_ grants: [AllocationGrant]) -> [Int: Int] {
        model.jobHistory.value?.charges(on: grants) ?? [:]
    }

    /// Kept apart from the grants, because none of this is charged until the job ends.
    private var runningLine: String? {
        let (count, rate) = (snapshot.runningCount, snapshot.runningCreditsPerHour)
        guard rate > 0 else { return nil }
        let soFar = Format.credits(Int(snapshot.runningCreditsSoFar.rounded()))
        let jobs = count == 1 ? "1 running job, charged when it ends" : "\(count) running jobs, charged when they end"
        return "\(jobs): \(Format.creditRate(rate)) SUs an hour, about \(soFar) so far"
    }
}

/// One grant: what the lab has used of it, what's left, and how much of that use was the user's.
private struct GrantCard: View {
    let grant: AllocationGrant
    /// The user's SUs on this grant. Nil when nobody has used it yet, or the history doesn't reach it.
    let mine: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(status: grant.phase(now: .now).status)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(grant.description.isEmpty ? "(unnamed)" : grant.description)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(period)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                // Shrinks rather than truncates: a clipped number would read as a different number.
                Text(Format.credits(grant.used))
                    .display(24)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("of \(Format.credits(grant.allocated)) SUs used")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Text(Format.percent(grant.usedFraction))
                    .font(.callout.weight(.semibold))
            }
            Meter(fraction: grant.usedFraction, height: 8)
                .help("\(Format.credits(grant.used)) of \(Format.credits(grant.allocated)) SUs used")
            // What an inactive grant has left can't be spent, so it isn't called remaining.
            Text(grant.isActive ? "\(Format.credits(grant.remaining)) SUs left" : "\(Format.credits(grant.remaining)) SUs went unused")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let mine {
                let share = Double(mine) / Double(max(grant.used, 1))
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("Mine")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.accent)
                    Text("\(Format.credits(mine)) SUs")
                        .font(.callout.weight(.semibold))
                    Text("· \(Format.percent(share)) of what the lab used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Meter(fraction: share, height: 6)
                    .help("\(Format.credits(mine)) of the \(Format.credits(grant.used)) SUs used on this grant")
            }
        }
        .monospacedDigit()
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
        .opacity(grant.isActive ? 1 : 0.65)
    }

    private var period: String {
        let start = grant.starts.map(Format.day) ?? "Unknown start"
        let end = grant.ends.map(Format.day) ?? "no end date"
        return "\(start) – \(end)"
    }
}
