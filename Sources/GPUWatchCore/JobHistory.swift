import Foundation

/// One job from Slurm's history, reduced to what the activity charts and grant shares need.
public struct PastJob: Sendable, Equatable {
    public let id: String
    /// Midnight here on the date the cluster printed, for the Mac's calendar.
    public let submitted: Date
    /// In UTC like `AllocationGrant`'s dates, since it's only compared against those.
    public let ended: Date?
    /// What the accounting system charges for it. Checked against 84 real charges, which all matched.
    public let charge: Int
}

/// A day or a month of a chart, and how many jobs were submitted in it.
public struct ActivitySlot: Identifiable, Sendable, Equatable {
    public let date: Date
    public let count: Int

    public var id: Date { date }
}

/// The user's jobs going back further than Slurm answers in one query.
public struct JobHistory: Sendable, Equatable {
    public let coveredFrom: Date
    public let today: Date
    /// By job ID, because a job running across two months comes back from both months' queries.
    public let jobs: [String: PastJob]
    /// GPU time by job ID and start. A requeued job has a run for each attempt, all of which held
    /// their GPUs, and so did failed and cancelled ones. With these, the hours match `sreport`.
    public let gpuRuns: [String: GPUInterval]

    private static let freeStates: Set<String> = ["BOOT_FAIL", "CANCELLED", "FAILED", "NODE_FAIL", "OUT_OF_MEMORY", "PREEMPTED"]

    /// Reads rows of `JobID|Submit|Start|End|State|ElapsedRaw|AllocTRES`.
    public static func parse(_ text: String) throws -> JobHistory {
        let output = RemoteOutput(text)
        guard output.isComplete, var section = output.sections["HISTORY"] else {
            throw FetchFailure(headline: "The connection dropped mid-update", detail: "The cluster's reply was incomplete.")
        }
        let rows = section.lines.filter { $0.contains("|") }
        section.lines = section.lines.filter { !$0.contains("|") }
        // A missing month would undercount without looking wrong, so this is all or nothing.
        if let message = section.failureMessage {
            throw FetchFailure(headline: "sacct", detail: message)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = formatter.locale
        timeFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let window = output.firstLine("HISTORY_WINDOW")?.split(separator: " ").compactMap { formatter.date(from: String($0)) } ?? []
        guard window.count == 2 else {
            throw FetchFailure(headline: "sacct", detail: "The cluster didn't report its dates.")
        }
        var jobs: [String: PastJob] = [:]
        var gpuRuns: [String: GPUInterval] = [:]
        var latestRun: [String: String] = [:]
        for row in rows {
            let fields = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7, let submitted = formatter.date(from: String(fields[1].prefix(10))) else { continue }
            if let run = gpuInterval(start: timeFormatter.date(from: fields[2]), seconds: fields[5], tres: fields[6]) {
                gpuRuns["\(fields[0])@\(fields[2])"] = run
            }
            // Only a job's last run decides what it's charged.
            if let latest = latestRun[fields[0]], latest > fields[2] { continue }
            latestRun[fields[0]] = fields[2]
            let ended = AllocationGrant.day(fields[3])
            jobs[fields[0]] = PastJob(
                id: fields[0],
                submitted: submitted,
                ended: ended,
                charge: charge(ended: ended, state: fields[4], seconds: fields[5], tres: fields[6])
            )
        }
        return JobHistory(coveredFrom: window[0], today: window[1], jobs: jobs, gpuRuns: gpuRuns)
    }

    private static func charge(ended: Date?, state: String, seconds: String, tres: String) -> Int {
        // "CANCELLED by 1234" still counts as cancelled.
        let outcome = String(state.split(separator: " ").first ?? "")
        guard ended != nil, !freeStates.contains(outcome),
              let billing = SlurmFormat.tresValue("billing", in: tres).flatMap({ Double($0) }),
              let seconds = Double(seconds)
        else { return 0 }
        return Int((billing / 10 * seconds / 3600).rounded())
    }

    /// From the job's start and how long it has run, which also covers a job still running.
    private static func gpuInterval(start: Date?, seconds: String, tres: String) -> GPUInterval? {
        guard let start, let seconds = Double(seconds), seconds > 0,
              let gpus = SlurmFormat.tresValue("gres/gpu", in: tres).flatMap({ Int($0) }), gpus > 0
        else { return nil }
        return GPUInterval(gpus: gpus, start: start, end: start.addingTimeInterval(seconds))
    }

    public var gpuUsage: GPUUsage {
        GPUUsage(intervals: Array(gpuRuns.values))
    }

    /// Takes a newer, shorter fetch: recent jobs may have changed, older ones can't have.
    public func merged(with newer: JobHistory) -> JobHistory {
        JobHistory(
            coveredFrom: min(coveredFrom, newer.coveredFrom),
            today: newer.today,
            jobs: jobs.merging(newer.jobs) { _, new in new },
            gpuRuns: gpuRuns.merging(newer.gpuRuns) { _, new in new }
        )
    }

    /// Each day of the current week.
    public func week(calendar: Calendar = .current) -> [ActivitySlot] {
        guard let start = calendar.dateInterval(of: .weekOfYear, for: today)?.start else { return [] }
        return slots(from: start, count: 7, unit: .day, calendar: calendar)
    }

    /// Each day of the current month.
    public func month(calendar: Calendar = .current) -> [ActivitySlot] {
        guard let start = calendar.dateInterval(of: .month, for: today)?.start,
              let days = calendar.range(of: .day, in: .month, for: today)
        else { return [] }
        return slots(from: start, count: days.count, unit: .day, calendar: calendar)
    }

    /// Each month of the current year.
    public func year(calendar: Calendar = .current) -> [ActivitySlot] {
        guard let start = calendar.dateInterval(of: .year, for: today)?.start else { return [] }
        return slots(from: start, count: 12, unit: .month, calendar: calendar)
    }

    private func slots(from start: Date, count: Int, unit: Calendar.Component, calendar: Calendar) -> [ActivitySlot] {
        (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: unit, value: offset, to: start),
                  let next = calendar.date(byAdding: unit, value: 1, to: date)
            else { return nil }
            return ActivitySlot(date: date, count: jobs.values.filter { $0.submitted >= date && $0.submitted < next }.count)
        }
    }

    /// What the user has been charged on each grant, by grant ID. A job goes to the grant open when
    /// it ended, the soonest to end if several are. A grant older than the history is left out,
    /// since only part of it could be counted.
    public func charges(on grants: [AllocationGrant]) -> [Int: Int] {
        var totals: [Int: Int] = [:]
        for grant in grants where (grant.starts ?? .distantPast) >= coveredFrom {
            totals[grant.id] = 0
        }
        for job in jobs.values where job.charge > 0 {
            guard let ended = job.ended else { continue }
            let open = grants.filter { ($0.starts ?? .distantPast) <= ended && ended < ($0.ends ?? .distantFuture) }
            guard let grant = open.min(by: { ($0.ends ?? .distantFuture) < ($1.ends ?? .distantFuture) }) else { continue }
            totals[grant.id]? += job.charge
        }
        return totals
    }
}
