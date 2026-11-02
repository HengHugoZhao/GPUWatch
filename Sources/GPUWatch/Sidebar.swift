import GPUWatchCore
import SwiftUI

/// Each machine at a glance, so the other one can be checked without switching pages.
/// Cards rather than a `List`, whose solid selection color would hide the bars inside a row.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    private static let titleBarHeight: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    MachineCard(page: .server, shortcut: "1") {
                        if let snapshot = model.server.value {
                            ServerGlance(snapshot: snapshot)
                        }
                    }
                    MachineCard(page: .hpc, shortcut: "2") {
                        if let snapshot = model.hpc.value {
                            HPCGlance(snapshot: snapshot)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, Self.titleBarHeight)
                .padding(.vertical, 6)
            }
            // Left alone, a scroll view in this column clears the title bar twice over.
            .ignoresSafeArea(.container, edges: .top)
            WeeklyGPUHours()
                .padding(.horizontal, 10)
                .padding(.top, 10)
            SignedInRow()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
    }
}

private struct MachineCard<Content: View>: View {
    @Environment(AppModel.self) private var model
    let page: AppModel.Page
    let shortcut: KeyEquivalent
    @ViewBuilder let content: Content

    private static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10) }

    private var isSelected: Bool { model.page == page }

    var body: some View {
        Button {
            model.page = page
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: page.symbol)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(page.title)
                            .fontWeight(.medium)
                        HStack(spacing: 3) {
                            if model.hasFailure(page) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Theme.serious)
                            }
                            Text(model.summary(page))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                content
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(HoverRowStyle())
        .keyboardShortcut(shortcut)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05), in: Self.shape)
        .clipShape(Self.shape)
        .overlay {
            if isSelected {
                Self.shape.strokeBorder(Color.accentColor, lineWidth: 1)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ServerGlance: View {
    let snapshot: ServerSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 3) {
                ForEach(snapshot.gpus) { gpu in
                    let status = gpu.availability.status
                    RoundedRectangle(cornerRadius: 2)
                        .fill(status.color)
                        .frame(height: 10)
                        .help("GPU \(gpu.index): \(status.text)")
                }
            }
            GlanceRow(label: "My jobs", value: "\(snapshot.myJobs.count) running")
            if let memory = snapshot.memory {
                GlanceMeter(label: "CPU memory", usedMB: memory.usedMB, totalMB: memory.totalMB)
            }
            if let storage = snapshot.storage {
                GlanceMeter(storage: storage)
            }
        }
    }
}

private struct HPCGlance: View {
    let snapshot: HPCSnapshot

    private var jobs: String {
        snapshot.pendingCount > 0
            ? "\(snapshot.runningCount) running · \(snapshot.pendingCount) pending"
            : "\(snapshot.runningCount) running"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GPUBar(counts: snapshot.totals)
            GlanceRow(label: "My jobs", value: jobs)
            if snapshot.memoryTotalMB > 0 {
                GlanceMeter(label: "CPU memory", usedMB: snapshot.memoryAllocatedMB, totalMB: snapshot.memoryTotalMB)
            }
            ForEach(snapshot.storage) { GlanceMeter(storage: $0) }
        }
    }
}

struct GlanceRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
        }
        .font(.caption)
        .monospacedDigit()
        .lineLimit(1)
    }
}

private struct GlanceMeter: View {
    let label: String
    let usedMB: Int
    let totalMB: Int

    private var fraction: Double { totalMB > 0 ? Double(usedMB) / Double(totalMB) : 0 }

    var body: some View {
        VStack(spacing: 3) {
            GlanceRow(label: label, value: Format.percent(fraction))
            Meter(fraction: fraction, height: 5)
        }
        .help("\(Format.memory(mb: usedMB)) of \(Format.memory(mb: totalMB))")
    }
}

extension GlanceMeter {
    /// By the path's last part, since a whole path doesn't fit here.
    init(storage: StorageUsage) {
        self.init(
            label: URL(fileURLWithPath: storage.path).lastPathComponent,
            usedMB: storage.usedMB,
            totalMB: storage.totalMB
        )
    }
}

/// Who the app is showing, since that's a choice now, and the way to change it.
private struct SignedInRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
            Text(model.user ?? "")
                .lineLimit(1)
                .help("Signed in as \(model.user ?? "")")
            Spacer(minLength: 4)
            Button("Switch User") { model.signOut() }
                .buttonStyle(.link)
                .help("Sign out and choose another computing ID")
        }
        .font(.caption)
        .padding(.horizontal, 10)
    }
}

/// Both machines' GPU hours over the same recent weeks, the one view that sets them side by side.
private struct WeeklyGPUHours: View {
    @Environment(AppModel.self) private var model

    private static let weeksShown = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("My GPU hours this week")
                .font(.caption)
                .foregroundStyle(.secondary)
            row(AppModel.Page.server.title, usage: model.serverUsage.usage, today: .now)
            if let history = model.jobHistory.value {
                row(AppModel.Page.hpc.title, usage: history.gpuUsage, today: history.today)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ name: String, usage: GPUUsage, today: Date) -> some View {
        let weeks = usage.weeks(count: Self.weeksShown, through: today)
        return VStack(spacing: 4) {
            GlanceRow(label: name, value: Format.hours(weeks.last?.hours ?? 0))
            WeekBars(weeks: weeks)
        }
    }
}

/// A few weeks small enough to need no axis. A week with nothing shows as a low bit of track.
private struct WeekBars: View {
    let weeks: [UsageSlot]

    private static let height: CGFloat = 22
    private static let emptyHeight: CGFloat = 2

    var body: some View {
        let peak = max(weeks.map(\.hours).max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(weeks) { week in
                RoundedRectangle(cornerRadius: 1)
                    .fill(week.hours > 0 ? Theme.meter : Theme.barTrack)
                    .frame(height: max(Self.height * week.hours / peak, Self.emptyHeight))
                    .frame(maxWidth: .infinity)
                    .help("Week of \(week.date.formatted(.dateTime.month(.abbreviated).day())): \(Format.hours(week.hours)) GPU hours")
            }
        }
        .frame(height: Self.height, alignment: .bottom)
    }
}
