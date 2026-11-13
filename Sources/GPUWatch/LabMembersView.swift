import GPUWatchCore
import SwiftUI

/// Everyone on the lab's account and what they hold right now. A row opens to list their jobs.
struct LabMembersSection: View {
    @Environment(AppModel.self) private var model
    let snapshot: HPCSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Lab members", detail: summary)
            if let failure = model.labMembers.failure {
                SectionError(message: "\(failure.headline): \(failure.detail)")
            }
            if let lab = model.labMembers.value {
                Panel {
                    ForEach(lab.members) { member in
                        if member.id != lab.members.first?.id {
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                        }
                        MemberRow(member: member, isMe: member.id == snapshot.me, snapshot: snapshot, isExpanded: binding(for: member.id))
                    }
                }
                Text("Everyone on \(lab.account), with the CPUs, memory and GPUs their running jobs hold. Refreshes every 2 minutes and when you refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.labMembers.isLoading {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var summary: String? {
        guard let lab = model.labMembers.value else { return nil }
        return "\(lab.members.count) on \(lab.account) · \(lab.activeCount) with jobs running · \(lab.gpus) \(lab.gpus == 1 ? "GPU" : "GPUs") held"
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { model.expandedMembers.contains(id) },
            set: { isOpen in
                if isOpen { model.expandedMembers.insert(id) } else { model.expandedMembers.remove(id) }
            }
        )
    }
}

private struct MemberRow: View {
    let member: LabMember
    let isMe: Bool
    let snapshot: HPCSnapshot
    @Binding var isExpanded: Bool

    private static let avatarSize: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    Chevron(isOpen: isExpanded)
                        .opacity(member.isIdle ? 0 : 1)
                    avatar
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(member.name ?? member.id)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                            if isMe { Tag(text: "You") }
                        }
                        if member.name != nil {
                            Text(member.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 12)
                    resources
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverRowStyle())
            .disabled(member.isIdle)
            if isExpanded && !member.isIdle {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(member.runningJobs + member.pendingJobs) { job in
                        MemberJobRow(job: job, snapshot: snapshot)
                    }
                }
                .padding(.leading, 62)
                .padding(.trailing, 14)
                .padding(.bottom, 10)
            }
        }
    }

    /// Initials from the name, or the ID's first letters when there's no name on file.
    private var avatar: some View {
        let initials: String
        if let name = member.name {
            initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        } else {
            initials = String(member.id.prefix(2))
        }
        return Text(initials.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(member.runningJobs.isEmpty ? .secondary : Theme.accent)
            .frame(width: Self.avatarSize, height: Self.avatarSize)
            .background(member.runningJobs.isEmpty ? Theme.surfaceRaised : Theme.accentSoft, in: Circle())
    }

    @ViewBuilder private var resources: some View {
        if member.isIdle {
            Text("No jobs")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 6) {
                if !member.runningJobs.isEmpty {
                    if member.gpus > 0 { Pill(text: "\(member.gpus) \(member.gpus == 1 ? "GPU" : "GPUs")", isStrong: true) }
                    Pill(text: "\(member.cpus) CPUs")
                    Pill(text: Format.memory(mb: member.memoryMB))
                }
                if !member.pendingJobs.isEmpty {
                    Text("\(member.pendingJobs.count) queued")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }
            }
        }
    }
}

/// An amount a member holds, as a small rounded label.
private struct Pill: View {
    let text: String
    var isStrong = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(isStrong ? Theme.accent : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isStrong ? Theme.accentSoft : Theme.surfaceRaised, in: Capsule())
    }
}

/// One of a member's jobs: what it is, where it runs or why it waits, what it holds, and its time.
private struct MemberJobRow: View {
    let job: SlurmJob
    let snapshot: HPCSnapshot

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusDot(status: job.phase.status)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 1) {
                Text(job.name.isEmpty ? "(unnamed)" : job.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(place)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(holds)
                .font(.caption)
                .frame(width: 210, alignment: .trailing)
            Text(time)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
        }
        .monospacedDigit()
        .padding(.vertical, 5)
    }

    /// The job ID and partition, then the node once it runs or why it waits.
    private var place: String {
        let where_ = job.phase == .pending ? job.pendingExplanation : job.nodesOrReason
        return ([job.id, job.partition] + [where_].compactMap { $0 }).joined(separator: " · ")
    }

    private var holds: String {
        var parts: [String] = []
        if let count = job.gpuCount, count > 0 {
            parts.append(UserLookup.type(of: job, snapshot: snapshot).map { "\(count) × \($0)" } ?? "\(count) GPU\(count == 1 ? "" : "s")")
        }
        if let cpus = job.cpus { parts.append("\(cpus) CPUs") }
        if let memory = job.allocatedMemoryMB { parts.append(Format.memory(mb: memory)) }
        return parts.joined(separator: " · ")
    }

    private var time: String {
        guard job.phase != .pending else { return job.limitSeconds.map { "asks for \(Format.duration($0))" } ?? "" }
        let used = job.elapsedSeconds.map(Format.duration) ?? "?"
        return job.limitSeconds.map { "\(used) of \(Format.duration($0))" } ?? used
    }
}
