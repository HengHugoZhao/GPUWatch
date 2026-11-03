import AppKit
import GPUWatchCore
import Observation

/// One machine's latest data. A failed refresh keeps the last good value on screen.
struct Feed<Value> {
    var value: Value?
    var updatedAt: Date?
    var failure: FetchFailure?
    var isLoading = false
}

@MainActor
@Observable
final class AppModel {
    enum Page: CaseIterable, Identifiable {
        case server, hpc

        var id: Self { self }

        var title: String {
            switch self {
            case .server: return "ZheServer"
            case .hpc: return "UVA HPC"
            }
        }

        var symbol: String {
            switch self {
            case .server: return "server.rack"
            case .hpc: return "cpu"
            }
        }
    }

    /// Slurm state moves slowly and login nodes are shared, so the cluster gets asked less often.
    private static let serverInterval: TimeInterval = 30
    private static let hpcInterval: TimeInterval = 60
    /// Often enough that GPU hours on ZheServer keep adding up with the window hidden.
    private static let hiddenServerInterval: TimeInterval = 300
    /// A backstop: charges mostly refresh when a job ends. It's the cluster's slowest query.
    private static let chargesInterval: TimeInterval = 900
    /// MAM records a charge a few seconds after a job leaves the queue.
    private static let chargeDelay: Duration = .seconds(15)

    /// Who the app signs in as on both machines. Nil shows the sign-in page.
    private(set) var user: String?
    var page: Page = .server
    private(set) var server = Feed<ServerSnapshot>()
    private(set) var hpc = Feed<HPCSnapshot>()
    private(set) var charges = Feed<MyCharges>()
    private(set) var jobHistory = Feed<JobHistory>()
    private(set) var serverUsage = ServerUsageLedger()

    // Which rows are open. Kept here so they survive refreshes and switching pages.
    var expandedJobs: Set<String> = []
    var expandedGPUTypes: Set<String> = []
    var showsFinishedJobs = false
    var showsAllActiveJobs = false
    var showsInactiveGrants = false
    var showsInactiveShares = false

    private var started = false
    private var chargesRequestedAt: Date?
    /// Bumped at each sign-in and sign-out, so a fetch still running for the last user is dropped.
    private var session = 0
    @ObservationIgnored private var pollers: [Task<Void, Never>] = []
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private static let savedUserKey = "signedInUser"

    init() {
        if let saved = UserDefaults.standard.string(forKey: Self.savedUserKey).flatMap(ComputingID.normalized) {
            user = saved
            serverUsage = Self.loadServerUsage(for: saved)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        observeSystem()
        startPolling()
    }

    private func startPolling() {
        guard started, user != nil, pollers.isEmpty else { return }
        pollers = [
            Task { await poll(every: Self.serverInterval, whenHidden: Self.hiddenServerInterval) { await self.refreshServer() } },
            Task { await poll(every: Self.hpcInterval) { await self.refreshHPC() } },
        ]
    }

    // MARK: - Signing in

    /// Remembering is the only thing saved: without it, the next launch asks again.
    func signIn(as id: String, remember: Bool) {
        guard let id = ComputingID.normalized(id) else { return }
        if remember {
            UserDefaults.standard.set(id, forKey: Self.savedUserKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.savedUserKey)
        }
        session += 1
        user = id
        serverUsage = Self.loadServerUsage(for: id)
        startPolling()
    }

    /// Forgets the saved ID too, and everything on screen, so nothing of one user's shows for the next.
    func signOut() {
        guard let previous = user else { return }
        pollers.forEach { $0.cancel() }
        pollers = []
        session += 1
        user = nil
        UserDefaults.standard.removeObject(forKey: Self.savedUserKey)
        page = .server
        server = Feed()
        hpc = Feed()
        charges = Feed()
        jobHistory = Feed()
        serverUsage = ServerUsageLedger()
        chargesRequestedAt = nil
        expandedJobs = []
        expandedGPUTypes = []
        showsFinishedJobs = false
        showsAllActiveJobs = false
        showsInactiveGrants = false
        showsInactiveShares = false
        Task {
            await SSH.dropConnection(on: RemoteScripts.serverMachine, as: previous)
            await SSH.dropConnection(on: RemoteScripts.hpcMachine, as: previous)
        }
    }

    func refreshCurrentPage() {
        switch page {
        case .server: Task { await refreshServer() }
        case .hpc: Task { await refreshHPC(includingCharges: true) }
        }
    }

    func isLoading(_ page: Page) -> Bool {
        page == .server ? server.isLoading : hpc.isLoading
    }

    func updatedAt(_ page: Page) -> Date? {
        page == .server ? server.updatedAt : hpc.updatedAt
    }

    /// What the sidebar shows under each machine's name.
    func summary(_ page: Page) -> String {
        switch page {
        case .server:
            if server.failure != nil && server.value == nil { return "Can't connect" }
            guard let value = server.value else { return "Connecting…" }
            return "\(value.count(.free)) free · \(value.count(.partlyFree)) partly free"
        case .hpc:
            if hpc.failure != nil && hpc.value == nil { return "Can't connect" }
            guard let value = hpc.value else { return "Connecting…" }
            return "\(value.totals.ready) ready · \(value.runningCount) running"
        }
    }

    func hasFailure(_ page: Page) -> Bool {
        page == .server ? server.failure != nil : hpc.failure != nil
    }

    /// The first load ignores visibility: at launch the window may not be on screen yet,
    /// or may have opened behind another one.
    private func poll(every interval: TimeInterval, whenHidden hiddenInterval: TimeInterval? = nil, _ refresh: () async -> Void) async {
        await refresh()
        var refreshedAt = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            let hiddenIsDue = hiddenInterval.map { Date().timeIntervalSince(refreshedAt) >= $0 } ?? false
            if isWindowVisible || hiddenIsDue {
                await refresh()
                refreshedAt = Date()
            }
        }
    }

    private func refreshServer() async {
        let previousUpdate = server.updatedAt
        await refresh(\.server) { try await Fetch.server(as: $0) }
        // Only a fresh reading: a failed refresh leaves the old one, whose ages are out of date.
        guard server.updatedAt != previousUpdate, let snapshot = server.value else { return }
        let before = serverUsage
        serverUsage.observe(snapshot)
        if serverUsage != before { saveServerUsage() }
    }

    // MARK: - ZheServer usage

    /// Kept on the Mac, because nothing on ZheServer remembers it and the app doesn't write there.
    /// One file per user, so people sharing a Mac don't add up. Test runs read a sample and never
    /// touch the real files.
    private static func usageFile(for user: String) -> URL? {
        guard ProcessInfo.processInfo.environment["GPUWATCH_FIXTURES"] == nil else { return nil }
        return try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("GPU Watch/zheserver-gpu-usage-\(user).json")
    }

    private static func loadServerUsage(for user: String) -> ServerUsageLedger {
        if let fixtures = ProcessInfo.processInfo.environment["GPUWATCH_FIXTURES"] {
            let sample = URL(fileURLWithPath: fixtures).appendingPathComponent("ZheServerUsage.json")
            return (try? Data(contentsOf: sample)).flatMap { try? ServerUsageLedger.decoded(from: $0) } ?? ServerUsageLedger()
        }
        guard let file = usageFile(for: user) else { return ServerUsageLedger() }
        guard let data = try? Data(contentsOf: file) else { return ServerUsageLedger() }
        if let ledger = try? ServerUsageLedger.decoded(from: data) { return ledger }
        // This can't be rebuilt, so an unreadable file is set aside rather than written over.
        try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("unreadable"))
        return ServerUsageLedger()
    }

    private func saveServerUsage() {
        guard let user, let file = Self.usageFile(for: user), let data = try? serverUsage.encoded() else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private func refreshHPC(includingCharges: Bool = false) async {
        let runningBefore = Set(hpc.value?.runningJobs.map(\.id) ?? [])
        let activeBefore = Set(hpc.value?.activeJobs.map(\.id) ?? [])
        await refresh(\.hpc) { try await Fetch.hpc(as: $0) }
        let jobEnded = !runningBefore.isSubset(of: Set(hpc.value?.runningJobs.map(\.id) ?? []))
        // A newly submitted job should count right away, not at the next 15-minute refresh.
        let jobsChanged = activeBefore != Set(hpc.value?.activeJobs.map(\.id) ?? [])
        if includingCharges || jobsChanged || isStale(jobHistory.updatedAt, Self.chargesInterval) {
            Task { await refreshJobHistory() }
        }
        guard includingCharges || jobEnded || isStale(chargesRequestedAt, Self.chargesInterval) else { return }
        chargesRequestedAt = .now
        Task {
            if jobEnded { try? await Task.sleep(for: Self.chargeDelay) }
            await refresh(\.charges) { try await Fetch.myCharges(as: $0) }
        }
    }

    /// Everything on the first load, then only this month and last, since older jobs can't change.
    private func refreshJobHistory() async {
        let previous = jobHistory.value
        await refresh(\.jobHistory) { user in
            let newer = try await Fetch.jobHistory(monthsBack: previous == nil ? RemoteScripts.jobHistoryMonths : 1, as: user)
            return previous?.merged(with: newer) ?? newer
        }
    }

    private func refresh<Value>(
        _ feed: ReferenceWritableKeyPath<AppModel, Feed<Value>>,
        fetch: (String) async throws -> Value
    ) async {
        guard let user, !self[keyPath: feed].isLoading else { return }
        let session = self.session
        self[keyPath: feed].isLoading = true
        defer { if self.session == session { self[keyPath: feed].isLoading = false } }
        let result: Result<Value, FetchFailure>
        do {
            result = .success(try await fetch(user))
        } catch let failure as FetchFailure {
            result = .failure(failure)
        } catch {
            result = .failure(FetchFailure(headline: "Update failed", detail: error.localizedDescription))
        }
        guard self.session == session else { return }
        switch result {
        case .success(let value):
            self[keyPath: feed].value = value
            self[keyPath: feed].updatedAt = .now
            self[keyPath: feed].failure = nil
        case .failure(let failure):
            self[keyPath: feed].failure = failure
        }
    }

    // MARK: - Visibility and sleep

    /// The cluster isn't polled while the window is hidden, so a forgotten app doesn't keep
    /// querying a shared login node. ZheServer only slows down, to keep its GPU hours going.
    private var isWindowVisible: Bool {
        NSApp.occlusionState.contains(.visible)
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        let occlusion = center.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshIfStale() }
        }
        observers.append((center, occlusion))

        let workspace = NSWorkspace.shared.notificationCenter
        let wake = workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reconnectAfterWake() }
        }
        observers.append((workspace, wake))
    }

    private func refreshIfStale() {
        guard isWindowVisible else { return }
        if isStale(server.updatedAt, Self.serverInterval) { Task { await refreshServer() } }
        if isStale(hpc.updatedAt, Self.hpcInterval) { Task { await refreshHPC() } }
    }

    private func isStale(_ date: Date?, _ interval: TimeInterval) -> Bool {
        guard let date else { return true }
        return Date().timeIntervalSince(date) >= interval
    }

    /// The shared SSH connections didn't survive the sleep; waiting for keep-alives
    /// to notice would leave a stale screen for half a minute.
    private func reconnectAfterWake() async {
        guard let user else { return }
        await SSH.dropConnection(on: RemoteScripts.serverMachine, as: user)
        await SSH.dropConnection(on: RemoteScripts.hpcMachine, as: user)
        guard isWindowVisible, self.user == user else { return }
        Task { await refreshServer() }
        Task { await refreshHPC() }
    }
}
