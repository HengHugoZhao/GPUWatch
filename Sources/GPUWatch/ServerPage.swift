import GPUWatchCore
import SwiftUI

struct ServerPage: View {
    let snapshot: ServerSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            ServerJobsSection(jobs: snapshot.myJobs, snapshot: snapshot)
            VStack(alignment: .leading, spacing: 18) {
                HeadlineRow(hero: { hero }, side: cpuMemory)
                Panel {
                    ServerHeaderRow()
                    ForEach(snapshot.gpus) { gpu in
                        Divider()
                        ServerGPURow(gpu: gpu, me: snapshot.me)
                    }
                }
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            StorageSection(
                storage: snapshot.storage.map { [$0] } ?? [],
                error: snapshot.storageError,
                errorSource: RemoteScripts.serverStoragePath
            )
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(snapshot.count(.free))")
                    .font(.system(size: 40, weight: .semibold))
                Text("of \(snapshot.gpus.count) GPUs free")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Text("\(snapshot.count(.partlyFree)) partly free · \(snapshot.count(.full)) full · \(snapshot.hostname) · \(snapshot.hardwareSummary)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var cpuMemory: UsageMeter? {
        snapshot.memory.map { memory in
            UsageMeter(
                title: "CPU memory",
                usedMB: memory.usedMB,
                totalMB: memory.totalMB,
                usedWord: "in use",
                remainderWord: "available",
                explanation: "In use is the total minus what Linux reports as available, so disk cache it can reclaim doesn't count."
            )
        }
    }

    private var footnote: String {
        let percent = Int(GPUAvailability.partlyFreeThreshold * 100)
        return "Free: nothing running. Partly free: something is running, but at least \(percent)% of its memory is unused. "
            + "Full: under \(percent)% of its memory is unused. Refreshes every 30 seconds."
    }
}

// MARK: - My jobs

private struct ServerJobsSection: View {
    @Environment(AppModel.self) private var model
    let jobs: [ServerJob]
    let snapshot: ServerSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "My jobs", detail: jobs.isEmpty ? "Nothing running on a GPU" : "\(jobs.count) running")
            if !jobs.isEmpty {
                Panel {
                    CappedScroll {
                        ForEach(jobs) { job in
                            if job.id != jobs.first?.id { Divider() }
                            ServerJobRow(job: job, snapshot: snapshot, isExpanded: binding(for: job.id))
                        }
                    }
                }
            }
            GPUHoursPanel(usage: model.serverUsage.usage, today: .now, note: gpuHoursNote)
        }
    }

    /// This machine keeps no history, so the panel says how far its numbers can be trusted.
    private var gpuHoursNote: String {
        let since = model.serverUsage.usage.firstStart.map { " since \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? ""
        return "What this app has seen running\(since). Jobs that start and end while it's closed aren't counted."
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

private struct ServerJobRow: View {
    let job: ServerJob
    let snapshot: ServerSnapshot
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
                        JobPhase.running.status
                            .frame(width: 112, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.shortCommand)
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
                        if let elapsed = job.elapsedSeconds {
                            Text("Running \(Format.duration(elapsed))")
                                .font(.callout)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                    ServerJobUsage(job: job, snapshot: snapshot)
                        .padding(.leading, Self.usageInset)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .buttonStyle(HoverRowStyle())
            if isExpanded {
                DetailGrid(rows: details)
                    .padding(.leading, 36)
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
                    .padding(.top, 2)
            }
        }
    }

    private var resourceLine: String {
        let gpuList = job.gpuIndexes.map(String.init).joined(separator: ", ")
        var parts = ["\(job.gpuIndexes.count == 1 ? "GPU" : "GPUs") \(gpuList)"]
        parts.append(job.pids.count == 1 ? "1 process" : "\(job.pids.count) processes")
        return parts.joined(separator: " · ")
    }

    private var details: [(String, String)] {
        var rows = [("Command", job.commandLine ?? job.shortCommand)]
        if let workDir = job.workDir { rows.append(("Working directory", workDir)) }
        rows.append(("Process IDs", job.pids.map(String.init).joined(separator: ", ")))
        return rows
    }
}

/// What a job is using. Nothing is reserved on this machine, so CPU and RAM are out of the whole
/// machine, which is what the job shares with everyone else.
private struct ServerJobUsage: View {
    let job: ServerJob
    let snapshot: ServerSnapshot

    private static let spacing: CGFloat = 16

    var body: some View {
        HStack(alignment: .top, spacing: Self.spacing) {
            cpu
            ram
            gpuMemory
        }
    }

    private var cpu: UsageCell {
        guard let cores = job.cpuCores else {
            return UsageCell(label: "CPU", value: "–", fraction: nil, explanation: "The server didn't report this job's CPU time.")
        }
        let machine = snapshot.cpuCount.map { " The machine has \($0)." } ?? ""
        return UsageCell(
            label: "CPU",
            value: Format.cores(cores),
            fraction: snapshot.cpuCount.map { cores / Double($0) },
            explanation: "Cores kept busy on average since the job started, including its data loader workers.\(machine)"
        )
    }

    private var ram: UsageCell {
        guard let used = job.ramMB else {
            return UsageCell(label: "RAM", value: "–", fraction: nil, explanation: "The server didn't report this job's RAM.")
        }
        let total = snapshot.memory?.totalMB
        let machine = total.map { " The machine has \(Format.memory(mb: $0))." } ?? ""
        return UsageCell(
            label: "RAM",
            value: Format.memory(mb: used),
            fraction: total.map { Double(used) / Double($0) },
            explanation: "Right now, including its data loader workers. Added up per process, so memory that workers share counts more than once.\(machine)"
        )
    }

    private var gpuMemory: UsageCell {
        guard let used = job.memoryMiB, job.gpuMemoryTotalMiB > 0 else {
            return UsageCell(label: "GPU memory", value: "–", fraction: nil, explanation: "nvidia-smi didn't report this job's GPU memory.")
        }
        return UsageCell(
            label: "GPU memory",
            value: Format.memoryPair(usedMB: used, totalMB: job.gpuMemoryTotalMiB),
            fraction: Double(used) / Double(job.gpuMemoryTotalMiB),
            explanation: "Out of everything on the GPUs it's using, which it may share with other jobs."
        )
    }
}

// MARK: - GPUs

private enum Column {
    static let index: CGFloat = 38
    static let status: CGFloat = 104
    static let utilization: CGFloat = 120
    static let temperature: CGFloat = 46
    static let power: CGFloat = 92
    static let spacing: CGFloat = 16
    static let horizontalPadding: CGFloat = 14
}

private struct ServerHeaderRow: View {
    var body: some View {
        HStack(spacing: Column.spacing) {
            Text("GPU").frame(width: Column.index, alignment: .leading)
            Text("Status").frame(width: Column.status, alignment: .leading)
            Text("Memory").frame(maxWidth: .infinity, alignment: .leading)
            Text("Utilization").frame(width: Column.utilization, alignment: .leading)
            Text("Temp").frame(width: Column.temperature, alignment: .trailing)
            Text("Power").frame(width: Column.power, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Column.horizontalPadding)
        .padding(.vertical, 8)
    }
}

private struct ServerGPURow: View {
    let gpu: ServerGPU
    let me: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Column.spacing) {
                Text("\(gpu.index)")
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .frame(width: Column.index, alignment: .leading)
                gpu.availability.status
                    .frame(width: Column.status, alignment: .leading)
                memory
                utilization
                Text(gpu.temperatureC.map { "\($0)°C" } ?? "–")
                    .monospacedDigit()
                    .frame(width: Column.temperature, alignment: .trailing)
                Text(power)
                    .monospacedDigit()
                    .frame(width: Column.power, alignment: .trailing)
            }
            ForEach(gpu.processes) { process in
                ProcessLine(process: process, isMine: process.user == me)
                    .padding(.leading, Column.index + Column.spacing)
            }
        }
        .padding(.horizontal, Column.horizontalPadding)
        .padding(.vertical, 10)
    }

    private var memory: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(Format.gib(mib: gpu.memoryUsedMiB)) / \(Format.gib(mib: gpu.memoryTotalMiB)) GiB")
                Spacer(minLength: 4)
                Text("\(Format.gib(mib: gpu.memoryFreeMiB)) free")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .monospacedDigit()
            .lineLimit(1)
            Meter(fraction: gpu.memoryFraction)
        }
        .frame(maxWidth: .infinity)
    }

    private var utilization: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(gpu.utilizationPercent.map { "\($0)%" } ?? "–")
                .font(.callout)
                .monospacedDigit()
            Meter(fraction: Double(gpu.utilizationPercent ?? 0) / 100)
        }
        .frame(width: Column.utilization)
    }

    private var power: String {
        guard let draw = gpu.powerDrawW else { return "–" }
        guard let limit = gpu.powerLimitW else { return "\(Int(draw)) W" }
        return "\(Int(draw)) / \(Int(limit)) W"
    }
}

private struct ProcessLine: View {
    let process: GPUProcess
    let isMine: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.fill")
                .foregroundStyle(.tertiary)
                .imageScale(.small)
            Text(isMine ? "You" : (process.user ?? "Unknown user"))
                .fontWeight(isMine ? .semibold : .regular)
                .foregroundStyle(.primary)
            Text(process.shortCommand)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let memory = process.memoryMiB {
                Text("\(Format.gib(mib: memory)) GiB")
            }
            if let elapsed = process.elapsedSeconds {
                Text(Format.duration(elapsed))
                    .frame(minWidth: 48, alignment: .trailing)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .help(process.commandLine ?? process.executable)
    }
}
