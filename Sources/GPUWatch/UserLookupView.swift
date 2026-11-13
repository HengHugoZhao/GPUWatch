import GPUWatchCore
import SwiftUI

/// Type anyone's computing ID to see whether they're using GPUs on UVA HPC right now, and which.
struct UserLookupSection: View {
    @Environment(AppModel.self) private var model
    let snapshot: HPCSnapshot

    private static let fieldWidth: CGFloat = 380
    private static let gpuWidth: CGFloat = 170
    private static let timeWidth: CGFloat = 150

    private var normalized: String? { ComputingID.normalized(model.lookupText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Who's using GPUs", detail: "Look up anyone on UVA HPC")
            HStack(spacing: 12) {
                // One search bar: the field and its button share a surface, like a browser's.
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Computing ID", text: Bindable(model).lookupText, prompt: Text("Computing ID, e.g. mst3k"))
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .onSubmit { model.lookUp(model.lookupText) }
                    if model.lookup.isLoading {
                        ProgressView().controlSize(.small)
                    }
                    Button("Look Up") { model.lookUp(model.lookupText) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(normalized == nil)
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .frame(width: Self.fieldWidth)
                .surface(radius: 10)
                if !model.lookupText.isEmpty && normalized == nil {
                    Text("A computing ID is letters and digits, like mst3k.")
                        .font(.caption)
                        .foregroundStyle(Theme.serious)
                }
            }
            if let failure = model.lookup.failure {
                SectionError(message: "\(failure.headline): \(failure.detail)")
            }
            if let lookup = model.lookup.value {
                result(lookup)
                if let checked = model.lookup.updatedAt {
                    Text("Checked at \(checked.formatted(date: .omitted, time: .shortened)), and again every 30 minutes and when you refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func result(_ lookup: UserLookup) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(lookup.name ?? lookup.id)
                        .font(.headline)
                    if lookup.name != nil {
                        Text(lookup.id).foregroundStyle(.secondary)
                    }
                    if lookup.id == model.user {
                        Tag(text: "You")
                    }
                }
                Text(headline(lookup))
                    .foregroundStyle(lookup.gpusNow > 0 ? .primary : .secondary)
                if !lookup.runningGPUJobs.isEmpty || !lookup.pendingGPUJobs.isEmpty {
                    Divider()
                    ForEach(lookup.runningGPUJobs + lookup.pendingGPUJobs) { job in
                        jobRow(job)
                    }
                }
                if lookup.otherRunningCount > 0 {
                    let count = lookup.otherRunningCount
                    Text("Also \(count) running \(count == 1 ? "job" : "jobs") without GPUs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headline(_ lookup: UserLookup) -> String {
        guard lookup.exists else { return "UVA HPC has no user \(lookup.id)." }
        let gpus = lookup.gpusNow
        guard gpus > 0 else {
            let pending = lookup.pendingGPUJobs.count
            return pending > 0
                ? "Not using any GPUs right now, with \(pending) GPU \(pending == 1 ? "job" : "jobs") waiting."
                : "Not using any GPUs right now."
        }
        return "Using \(gpus) \(gpus == 1 ? "GPU" : "GPUs") right now: \(lookup.gpuSummary(snapshot: snapshot))."
    }

    private func jobRow(_ job: SlurmJob) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            job.phase.status
                .frame(width: 100, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .fontWeight(.medium)
                    .truncationMode(.middle)
                Text(details(job))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(gpus(job))
                .frame(width: Self.gpuWidth, alignment: .trailing)
            Text(time(job))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: Self.timeWidth, alignment: .trailing)
        }
        .monospacedDigit()
        .lineLimit(1)
    }

    private func gpus(_ job: SlurmJob) -> String {
        let count = job.gpuCount ?? 0
        if let type = UserLookup.type(of: job, snapshot: snapshot) { return "\(count) × \(type)" }
        return count == 1 ? "1 GPU" : "\(count) GPUs"
    }

    /// The job ID and partition, then the node once it runs or why it waits.
    private func details(_ job: SlurmJob) -> String {
        let place = job.phase == .pending ? job.pendingExplanation : job.nodesOrReason
        return ([job.id, job.partition] + [place].compactMap { $0 }).joined(separator: " · ")
    }

    private func time(_ job: SlurmJob) -> String {
        guard job.phase != .pending else { return job.limitSeconds.map { "asks for \(Format.duration($0))" } ?? "" }
        let used = job.elapsedSeconds.map(Format.duration) ?? "?"
        return job.limitSeconds.map { "\(used) of \(Format.duration($0))" } ?? used
    }
}
