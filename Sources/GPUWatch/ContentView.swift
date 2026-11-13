import AppKit
import GPUWatchCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("isPinnedOnTop") private var isPinned = false
    @AppStorage("appearance") private var appearance = Appearance.system

    var body: some View {
        Group {
            if model.user == nil {
                SignInView()
            } else {
                pages
            }
        }
        .tint(Theme.accent)
        .background(WindowLevel(isOnTop: isPinned))
        .onChange(of: appearance, initial: true) { _, chosen in
            NSApp.appearance = chosen.nsAppearance
        }
    }

    private var pages: some View {
        NavigationSplitView {
            Sidebar()
                .toolbar {
                    ToolbarItem {
                        AppearanceMenu(appearance: $appearance)
                    }
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
                // The page's own canvas runs up under the bar, so the two read as one surface.
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
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

/// Light, dark, or whatever the Mac is set to. Applied to the whole app rather than as a SwiftUI
/// colour scheme, so the window's frame and the glass behind the page follow it too.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

private struct AppearanceMenu: View {
    @Binding var appearance: Appearance

    var body: some View {
        Menu {
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases) { option in
                    Label(option.title, systemImage: option.symbol).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Appearance", systemImage: appearance.symbol)
        }
        .menuIndicator(.hidden)
        .help("Appearance: \(appearance.title)")
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
            .fadesUnderTitleBar()
            // Under the title bar too, or the page and the bar above it meet in a hard step.
            .background {
                ZStack {
                    Glass()
                    Theme.canvasTint
                }
                .ignoresSafeArea()
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
        .surface(Theme.serious.opacity(0.10), border: Theme.serious.opacity(0.35))
    }
}

private extension View {
    /// The title bar draws no background, so content scrolled under it is hidden there and fades
    /// in just below, rather than running into the title. At rest nothing sits under the bar, so
    /// this only shows once the page scrolls.
    func fadesUnderTitleBar() -> some View {
        mask {
            GeometryReader { geometry in
                let bar = geometry.safeAreaInsets.top
                VStack(spacing: 0) {
                    Color.clear.frame(height: bar)
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 14)
                    Color.black
                }
                .frame(height: geometry.size.height + bar)
                .offset(y: -bar)
            }
        }
    }
}
