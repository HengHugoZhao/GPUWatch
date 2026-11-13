import GPUWatchCore
import SwiftUI

struct ServerPage: View {
    let snapshot: ServerSnapshot

    private static let cardMinimumWidth: CGFloat = 190

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            ServerJobsSection(jobs: snapshot.myJobs, snapshot: snapshot)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("GPUs").display(20)
                    Text("\(snapshot.hostname) · \(snapshot.hardwareSummary)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                ServerStats(snapshot: snapshot)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: Self.cardMinimumWidth), spacing: 12, alignment: .top)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(snapshot.gpus) { gpu in
                        GPUCard(gpu: gpu, me: snapshot.me)
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

    private var footnote: String {
        let percent = Int(GPUAvailability.partlyFreeThreshold * 100)
        return "Free: nothing running. Partly free: something is running, but at least \(percent)% of its memory is unused. "
            + "Full: under \(percent)% of its memory is unused. Refreshes every 30 seconds."
    }
}

/// The whole machine in five numbers: what's free, how hard the GPUs and CPUs work, and memory on each.
private struct ServerStats: View {
    let snapshot: ServerSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatTile(
                title: "GPUs free",
                value: "\(snapshot.count(.free)) of \(snapshot.gpus.count)",
                caption: "\(snapshot.count(.partlyFree)) partly free · \(snapshot.count(.full)) full"
            ) {
                HStack(spacing: 3) {
                    ForEach(snapshot.gpus) { gpu in
                        let status = gpu.availability.status
                        RoundedRectangle(cornerRadius: 2)
                            .fill(status.color)
                            .frame(height: 6)
                            .help("GPU \(gpu.index): \(status.text)")
                    }
                }
            }
            StatTile(
                title: "GPU utilization",
                value: snapshot.meanGPUUtilization.map(wholePercent) ?? "–",
                caption: "Average across the GPUs"
            ) {
                Meter(fraction: snapshot.meanGPUUtilization ?? 0)
            }
            StatTile(
                title: "GPU memory",
                value: Format.memory(mb: snapshot.gpuMemoryUsedMiB),
                caption: "in use of \(Format.memory(mb: snapshot.gpuMemoryTotalMiB))"
            ) {
                Meter(fraction: snapshot.gpuMemoryTotalMiB > 0 ? Double(snapshot.gpuMemoryUsedMiB) / Double(snapshot.gpuMemoryTotalMiB) : 0)
            }
            StatTile(title: "CPU", value: snapshot.cpuBusyFraction.map(wholePercent) ?? "–", caption: cpuCaption) {
                Meter(fraction: snapshot.cpuBusyFraction ?? 0)
            }
            .help("The one-minute load average over the number of cores: roughly how many cores have work to do.")
            StatTile(
                title: "CPU memory",
                value: snapshot.memory.map { Format.memory(mb: $0.usedMB) } ?? "–",
                caption: snapshot.memory.map { "in use of \(Format.memory(mb: $0.totalMB))" } ?? "Not reported"
            ) {
                Meter(fraction: snapshot.memory.map { Double($0.usedMB) / Double(max($0.totalMB, 1)) } ?? 0)
            }
            .help("In use is the total minus what Linux reports as available, so disk cache it can reclaim doesn't count.")
        }
    }

    private func wholePercent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    private var cpuCaption: String {
        guard let load = snapshot.loadAverage, let cores = snapshot.cpuCount else { return "Not reported" }
        return "\(Int(load.rounded())) of \(cores) cores busy"
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
                CappedScroll(maxHeight: 400) {
                    VStack(spacing: 8) {
                        ForEach(jobs) { job in
                            ServerJobRow(job: job, snapshot: snapshot, isExpanded: binding(for: job.id))
                                .surface()
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

    /// Past the chevron and the dot, so the rings start under the name.
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
                        StatusDot(status: JobPhase.running.status)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.shortCommand)
                                .fontWeight(.semibold)
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
                        .padding(.top, 4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
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

    private static let spacing: CGFloat = 20

    var body: some View {
        HStack(alignment: .top, spacing: Self.spacing) {
            cpu
            ram
            gpuBusy
            gpuMemory
        }
    }

    private var gpuBusy: UsageCell {
        let readings = snapshot.gpus.filter { job.gpuIndexes.contains($0.index) }.compactMap(\.utilizationPercent)
        guard !readings.isEmpty else {
            return UsageCell(label: "GPU", value: "–", fraction: nil, explanation: "nvidia-smi didn't report utilization for this job's GPUs.")
        }
        let mean = Double(readings.reduce(0, +)) / Double(readings.count) / 100
        return UsageCell(
            label: "GPU",
            value: "\(Int((mean * 100).rounded()))%",
            fraction: mean,
            explanation: "How busy the job's GPUs are right now, averaged over them. Anyone else on the same GPUs counts too."
        )
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

/// One GPU: how busy it is, how full its memory is, and who is on it.
private struct GPUCard: View {
    let gpu: ServerGPU
    let me: String

    private static let ringSize: CGFloat = 58
    private static let processesShown = 2
    /// The rule, two process lines and the "and N more" line.
    private static let processesHeight: CGFloat = 62

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("GPU \(gpu.index)")
                    .font(.headline)
                    .monospacedDigit()
                Spacer(minLength: 6)
                gpu.availability.status
                    .font(.caption)
            }
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Ring(fraction: utilization, lineWidth: 6)
                    VStack(spacing: -1) {
                        Text(gpu.utilizationPercent.map { "\($0)%" } ?? "–")
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                        Text("busy")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: Self.ringSize, height: Self.ringSize)
                .help("Utilization: how much of the last sample the GPU spent running work.")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory")
                        .eyebrow()
                        .foregroundStyle(.secondary)
                    Text("\(Format.gib(mib: gpu.memoryUsedMiB)) / \(Format.gib(mib: gpu.memoryTotalMiB)) GiB")
                        .font(.callout)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Meter(fraction: gpu.memoryFraction)
                }
            }
            HStack(spacing: 12) {
                Label(gpu.temperatureC.map { "\($0)°C" } ?? "–", systemImage: "thermometer.medium")
                Spacer(minLength: 4)
                Label(power, systemImage: "bolt")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .labelStyle(CompactLabel())
            processes
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }

    private var utilization: Double? { gpu.utilizationPercent.map { Double($0) / 100 } }

    private var power: String {
        guard let draw = gpu.powerDrawW else { return "–" }
        guard let limit = gpu.powerLimitW else { return "\(Int(draw)) W" }
        return "\(Int(draw)) / \(Int(limit)) W"
    }

    /// Room for every line it can show, so cards in a row come out the same height.
    @ViewBuilder private var processes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if gpu.processes.isEmpty {
                Text("Nothing running")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            ForEach(gpu.processes.prefix(Self.processesShown)) { process in
                ProcessLine(process: process, isMine: process.user == me)
            }
            if gpu.processes.count > Self.processesShown {
                Text("and \(gpu.processes.count - Self.processesShown) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(gpu.processes.dropFirst(Self.processesShown).map { "\($0.user ?? "Unknown user"): \($0.shortCommand)" }.joined(separator: "\n"))
            }
        }
        .frame(minHeight: Self.processesHeight, alignment: .top)
    }
}

private struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Who holds memory on a GPU and with what, short enough to fit a card.
private struct ProcessLine: View {
    let process: GPUProcess
    let isMine: Bool

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isMine {
                    Tag(text: "You")
                } else {
                    Text(process.user ?? "Unknown user")
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            // The script's name is the part worth keeping, so drop the interpreter when it won't fit.
            Text(process.shortCommand)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if let memory = process.memoryMiB {
                Text("\(Format.gib(mib: memory)) GiB")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .help([process.commandLine ?? process.executable, process.elapsedSeconds.map { "Running \(Format.duration($0))" }].compactMap { $0 }.joined(separator: "\n"))
    }
}
