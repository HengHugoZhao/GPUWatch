import Foundation

/// A stretch of time that some number of GPUs spent on the user's work.
public struct GPUInterval: Sendable, Equatable {
    public let gpus: Int
    public let start: Date
    public let end: Date

    public init(gpus: Int, start: Date, end: Date) {
        self.gpus = gpus
        self.start = start
        self.end = end
    }

    var hours: Double { hours(from: start, to: end) }

    func hours(from: Date, to: Date) -> Double {
        let overlap = min(end, to).timeIntervalSince(max(start, from))
        return overlap > 0 ? Double(gpus) * overlap / 3600 : 0
    }
}

/// A week or a month of a chart, and the GPU hours in it.
public struct UsageSlot: Identifiable, Sendable, Equatable {
    public let date: Date
    public let hours: Double

    public var id: Date { date }
}

/// The user's GPU hours on one machine. An interval is split across the weeks and months it
/// ran in, so a long job counts where the time actually went.
public struct GPUUsage: Sendable, Equatable {
    public let intervals: [GPUInterval]

    public init(intervals: [GPUInterval]) {
        self.intervals = intervals
    }

    public var firstStart: Date? { intervals.map(\.start).min() }
    public var totalHours: Double { intervals.map(\.hours).reduce(0, +) }

    /// The last `count` weeks, oldest first, ending with the one holding `today`.
    public func weeks(count: Int, through today: Date, calendar: Calendar = .current) -> [UsageSlot] {
        slots(of: .weekOfYear, count: count, through: today, calendar: calendar)
    }

    /// The last `count` months, oldest first, ending with the one holding `today`.
    public func months(count: Int, through today: Date, calendar: Calendar = .current) -> [UsageSlot] {
        slots(of: .month, count: count, through: today, calendar: calendar)
    }

    /// The total so far at each month from the first use through `today`, going back at least
    /// `minimumMonths` so that a short history doesn't fill a chart with one huge column.
    public func runningTotal(through today: Date, minimumMonths: Int = 1, calendar: Calendar = .current) -> [UsageSlot] {
        var count = minimumMonths
        if let first = firstStart,
           let firstMonth = calendar.dateInterval(of: .month, for: first)?.start,
           let thisMonth = calendar.dateInterval(of: .month, for: today)?.start {
            count = max((calendar.dateComponents([.month], from: firstMonth, to: thisMonth).month ?? 0) + 1, minimumMonths)
        }
        var total = 0.0
        return months(count: count, through: today, calendar: calendar).map { month in
            total += month.hours
            return UsageSlot(date: month.date, hours: total)
        }
    }

    private func slots(of unit: Calendar.Component, count: Int, through today: Date, calendar: Calendar) -> [UsageSlot] {
        guard let current = calendar.dateInterval(of: unit, for: today)?.start else { return [] }
        return (0..<count).reversed().compactMap { offset in
            guard let start = calendar.date(byAdding: unit, value: -offset, to: current),
                  let end = calendar.date(byAdding: unit, value: 1, to: start)
            else { return nil }
            return UsageSlot(date: start, hours: intervals.map { $0.hours(from: start, to: end) }.reduce(0, +))
        }
    }
}

/// What the app has seen the user running on ZheServer, because that machine keeps no usage
/// history of its own. A process counts from when it really started, known from its age, to
/// the last time it was seen, so gaps in the app's polling only cost the end of a job.
public struct ServerUsageLedger: Codable, Sendable, Equatable {
    public struct Record: Codable, Sendable, Equatable {
        public let gpu: Int
        public let pid: Int
        public let start: Date
        public var lastSeen: Date
    }

    public private(set) var records: [Record] = []

    /// Two sightings of one process disagree slightly about its start. A bigger gap means the
    /// PID has been reused by a new process.
    private static let startTolerance: TimeInterval = 120

    public init() {}

    public mutating func observe(_ snapshot: ServerSnapshot, at now: Date = .now) {
        for gpu in snapshot.gpus {
            for process in gpu.processes where process.user == snapshot.me {
                guard let elapsed = process.elapsedSeconds else { continue }
                observe(gpu: gpu.index, pid: process.pid, elapsedSeconds: elapsed, at: now)
            }
        }
    }

    public mutating func observe(gpu: Int, pid: Int, elapsedSeconds: Int, at now: Date) {
        let start = now.addingTimeInterval(-Double(elapsedSeconds))
        let known = records.lastIndex {
            $0.gpu == gpu && $0.pid == pid && abs($0.start.timeIntervalSince(start)) < Self.startTolerance
        }
        if let known {
            records[known].lastSeen = now
        } else {
            records.append(Record(gpu: gpu, pid: pid, start: start, lastSeen: now))
        }
    }

    /// A GPU counts once at any moment, however many of the user's processes share it.
    public var usage: GPUUsage {
        var intervals: [GPUInterval] = []
        for sameGPU in Dictionary(grouping: records, by: \.gpu).values {
            var current: (start: Date, end: Date)?
            for record in sameGPU.sorted(by: { $0.start < $1.start }) {
                if let open = current, record.start <= open.end {
                    current = (open.start, max(open.end, record.lastSeen))
                } else {
                    if let open = current { intervals.append(GPUInterval(gpus: 1, start: open.start, end: open.end)) }
                    current = (record.start, record.lastSeen)
                }
            }
            if let open = current { intervals.append(GPUInterval(gpus: 1, start: open.start, end: open.end)) }
        }
        return GPUUsage(intervals: intervals)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> ServerUsageLedger {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ServerUsageLedger.self, from: data)
    }
}
