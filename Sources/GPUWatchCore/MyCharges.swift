import Foundation

/// The charges for jobs that ended on one calendar day.
public struct ChargeDay: Identifiable, Sendable, Equatable {
    public let date: Date
    public let total: Int
    public let jobs: Int

    public var id: Date { date }

    /// The heatmap's scale, in SUs. Fixed rather than relative to the busiest day, so a day
    /// keeps its color when a bigger one comes along.
    public static let levelEdges = [100, 500, 1000, 2000]

    /// 0 with nothing charged, then one step for each edge reached.
    public var level: Int {
        total > 0 ? Self.levelEdges.filter { total >= $0 }.count + 1 : 0
    }

    public init(date: Date, total: Int, jobs: Int) {
        self.date = date
        self.total = total
        self.jobs = jobs
    }
}

/// What the accounting system has charged the user over `RemoteScripts.chargeWindowDays`.
public struct MyCharges: Sendable, Equatable {
    public let total: Int
    public let count: Int
    public let firstDay: Date
    public let lastDay: Date
    /// Only the days that have a charge, oldest first.
    public let days: [ChargeDay]

    public var busiestDay: ChargeDay? { days.max { $0.total < $1.total } }

    public func day(on date: Date) -> ChargeDay? { days.first { $0.date == date } }

    /// The window as a calendar: one entry per week, each with seven slots from the calendar's
    /// first weekday. A slot outside the window is nil.
    public func weeks(calendar: Calendar = .current) -> [[Date?]] {
        guard var start = calendar.dateInterval(of: .weekOfYear, for: firstDay)?.start else { return [] }
        var weeks: [[Date?]] = []
        while start <= lastDay {
            weeks.append((0..<7).map { offset in
                calendar.date(byAdding: .day, value: offset, to: start).flatMap { $0 >= firstDay && $0 <= lastDay ? $0 : nil }
            })
            guard let next = calendar.date(byAdding: .day, value: 7, to: start) else { break }
            start = next
        }
        return weeks
    }

    /// Reads rows of `Id,CreationTime,Amount`. Jobs cancelled within a second or so have a blank amount.
    public static func parse(_ text: String) throws -> MyCharges {
        let output = RemoteOutput(text)
        guard output.isComplete, let section = output.sections["CHARGES"] else {
            throw FetchFailure(headline: "The connection dropped mid-update", detail: "The cluster's reply was incomplete.")
        }
        if let message = section.failureMessage {
            throw FetchFailure(headline: "mam-list-transactions", detail: message)
        }
        let window = output.firstLine("WINDOW")?.split(separator: " ").compactMap { day(String($0)) } ?? []
        guard window.count == 2 else {
            throw FetchFailure(headline: "mam-list-transactions", detail: "The cluster didn't report its dates.")
        }
        var amounts: [Date: (sum: Double, jobs: Int)] = [:]
        for line in section.lines {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 3, Int(fields[0]) != nil, let date = day(String(fields[1].prefix(10))) else { continue }
            let (sum, jobs) = amounts[date] ?? (0, 0)
            amounts[date] = (sum + (Double(fields[2]) ?? 0), jobs + 1)
        }
        return MyCharges(
            total: Int(amounts.values.map(\.sum).reduce(0, +).rounded()),
            count: amounts.values.map(\.jobs).reduce(0, +),
            firstDay: window[0],
            lastDay: window[1],
            days: amounts
                .map { ChargeDay(date: $0.key, total: Int($0.value.sum.rounded()), jobs: $0.value.jobs) }
                .sorted { $0.date < $1.date }
        )
    }

    /// Midnight here on the date the cluster printed. Charts bin and label by the Mac's calendar,
    /// so this keeps a charge on the same date wherever the Mac is.
    private static func day(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}
