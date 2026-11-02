import AppKit
import GPUWatchCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("isPinnedOnTop") private var isPinned = false

    var body: some View {
        Group {
            if model.user == nil {
                SignInView()
            } else {
                pages
            }
        }
        .background(WindowLevel(isOnTop: isPinned))
    }

    private var pages: some View {
        NavigationSplitView {
            Sidebar()
                .toolbar {
                    ToolbarItem {
                        Button {
                            isPinned.toggle()
                        } label: {
                            Label(isPinned ? "Unpin" : "Keep on Top", systemImage: isPinned ? "pin.fill" : "pin")
                        }
                        .help(isPinned ? "Stop keeping this window on top" : "Keep this window on top of other apps")
                    }
                }
        } detail: {
            detail
                .navigationTitle(model.page.title)
                .toolbar {
                    ToolbarItem {
                        UpdatedLabel(date: model.updatedAt(model.page))
                    }
                    ToolbarItem {
                        Button {
                            model.refreshCurrentPage()
                        } label: {
                            if model.isLoading(model.page) {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                        .help("Refresh now (⌘R)")
                    }
                }
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.page {
        case .server:
            FeedPage(feed: model.server, host: RemoteScripts.serverHost, retry: model.refreshCurrentPage) { snapshot in
                ServerPage(snapshot: snapshot)
            }
        case .hpc:
            FeedPage(feed: model.hpc, host: RemoteScripts.hpcHost, retry: model.refreshCurrentPage) { snapshot in
                HPCPage(snapshot: snapshot)
            }
        }
    }
}

/// Reaches the window from AppKit, because SwiftUI's `windowLevel` belongs to the scene rather than
/// following a button. The window isn't attached yet on the first update, hence the wait.
private struct WindowLevel: NSViewRepresentable {
    let isOnTop: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let level: NSWindow.Level = isOnTop ? .floating : .normal
        DispatchQueue.main.async { view.window?.level = level }
    }
}

private struct UpdatedLabel: View {
    let date: Date?

    var body: some View {
        if let date {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Text("Updated \(Format.relative(date, now: context.date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.horizontal, 6)
            }
        }
    }
}

/// A page's three lives: first load, nothing to show, and data (possibly gone stale).
struct FeedPage<Value, Content: View>: View {
    let feed: Feed<Value>
    let host: String
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        if let value = feed.value {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let failure = feed.failure {
                        StaleBanner(failure: failure, updatedAt: feed.updatedAt, retry: retry)
                    }
                    content(value)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let failure = feed.failure {
            ContentUnavailableView {
                Label(failure.headline, systemImage: "network.slash")
            } description: {
                Text(failure.detail).textSelection(.enabled)
            } actions: {
                Button("Try Again", action: retry)
                    .disabled(feed.isLoading)
            }
        } else {
            ProgressView("Connecting to \(host)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Old numbers are worse than none if they pass as current, so this sits above them.
private struct StaleBanner: View {
    let failure: FetchFailure
    let updatedAt: Date?
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.serious)
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.headline).fontWeight(.medium)
                Group {
                    if let updatedAt {
                        Text("Showing data from \(Format.relative(updatedAt, now: .now)). \(failure.detail)")
                    } else {
                        Text(failure.detail)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            Spacer()
            Button("Try Again", action: retry)
        }
        .padding(12)
        .background(Theme.serious.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
