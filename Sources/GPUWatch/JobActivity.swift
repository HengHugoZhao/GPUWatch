import GPUWatchCore
import SwiftUI

/// How many jobs the user submitted this week, month and year, each over its own time scale,
/// and in total.
struct JobActivity: View {
    let history: JobHistory

    private static let monthsShown = 12

    var body: some View {
        HistoryPanel(
            title: "Jobs I submitted",
            note: history.firstSubmitted.map { "Since \($0.formatted(.dateTime.month(.abbreviated).year()))." },
            storageKey: "jobsHistoryTab",
            tabs: [
                tab("This week", slots: history.week(), scale: .week),
                tab("This month", slots: history.month(), scale: .month),
                tab("This year", slots: history.year(), scale: .year),
                totalTab(),
            ]
        )
    }

    /// Thinned out once the months stop fitting, counting back so the latest keeps its label.
    private func totalTab() -> HistoryTab {
        let totals = history.runningTotal(minimumMonths: Self.monthsShown)
        let total = history.jobs.count
        let every = totals.count <= Self.monthsShown + 2 ? 1 : 3
        return HistoryTab(
            caption: "In total",
            number: "\(total)",
            unit: total == 1 ? "job" : "jobs",
            columns: totals.enumerated().map { index, month in
                let isLabeled = (totals.count - 1 - index) % every == 0
                return SlotColumn(
                    value: Double(month.count),
                    label: isLabeled ? month.date.formatted(.dateTime.month(.abbreviated)) : nil,
                    tooltip: "Total by \(month.date.formatted(.dateTime.month(.wide).year())): \(month.count == 1 ? "1 job" : "\(month.count) jobs")"
                )
            },
            current: totals.indices.last
        )
    }

    private func tab(_ caption: String, slots: [ActivitySlot], scale: ActivityScale) -> HistoryTab {
        let total = slots.map(\.count).reduce(0, +)
        return HistoryTab(
            caption: caption,
            number: "\(total)",
            unit: total == 1 ? "job" : "jobs",
            columns: slots.map { slot in
                SlotColumn(
                    value: Double(slot.count),
                    label: scale.isLabeled(slot.date) ? slot.date.formatted(scale.labelFormat) : nil,
                    tooltip: "\(slot.date.formatted(scale.nameFormat)): \(slot.count == 1 ? "1 job" : "\(slot.count) jobs")"
                )
            },
            current: slots.lastIndex { $0.date <= history.today }
        )
    }
}

private enum ActivityScale {
    case week, month, year

    var labelFormat: Date.FormatStyle {
        switch self {
        case .week: return Date.FormatStyle().weekday(.narrow)
        case .month: return Date.FormatStyle().day()
        case .year: return Date.FormatStyle().month(.narrow)
        }
    }

    var nameFormat: Date.FormatStyle {
        switch self {
        case .week: return Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day()
        case .month: return Date.FormatStyle().month(.abbreviated).day()
        case .year: return Date.FormatStyle().month(.wide)
        }
    }

    /// A label on every slot, except a month's, which has too many to fit.
    func isLabeled(_ date: Date) -> Bool {
        self != .month || [1, 8, 15, 22, 29].contains(Calendar.current.component(.day, from: date))
    }
}

/// The user's GPU hours on one machine: per week, per month, this year, and in total.
struct GPUHoursPanel: View {
    let usage: GPUUsage
    let today: Date
    /// Where the numbers come from, which differs by machine.
    let note: String

    private static let weeksShown = 12
    private static let monthsShown = 12
    private static let weekLabelEvery = 2
    private static let monthFormat = Date.FormatStyle().month(.wide).year()

    var body: some View {
        let weeks = usage.weeks(count: Self.weeksShown, through: today)
        let months = usage.months(count: Self.monthsShown, through: today)
        let year = usage.year(holding: today)
        let totals = usage.runningTotal(through: today, minimumMonths: Self.monthsShown)
        HistoryPanel(
            title: "My GPU hours",
            note: note,
            storageKey: "gpuHoursHistoryTab",
            tabs: [
                HistoryTab(caption: "This week", number: Format.hours(weeks.last?.hours ?? 0), unit: "GPU hours",
                           columns: weekColumns(weeks), current: weeks.indices.last),
                HistoryTab(caption: "This month", number: Format.hours(months.last?.hours ?? 0), unit: "GPU hours",
                           columns: monthColumns(months), current: months.indices.last),
                HistoryTab(caption: "This year", number: Format.hours(year.map(\.hours).reduce(0, +)), unit: "GPU hours",
                           columns: monthColumns(year), current: year.lastIndex { $0.date <= today }),
                HistoryTab(caption: "In total", number: Format.hours(usage.totalHours), unit: "GPU hours",
                           columns: totalColumns(totals), current: totals.indices.last),
            ]
        )
    }

    private func hours(_ value: Double) -> String {
        "\(Format.hours(value)) GPU \(value == 1 ? "hour" : "hours")"
    }

    /// Counted back from the current week, so it always has its date.
    private func weekColumns(_ weeks: [UsageSlot]) -> [SlotColumn] {
        weeks.enumerated().map { index, week in
            let isLabeled = (weeks.count - 1 - index) % Self.weekLabelEvery == 0
            return SlotColumn(
                value: week.hours,
                label: isLabeled ? week.date.formatted(.dateTime.month(.abbreviated).day()) : nil,
                tooltip: "Week of \(week.date.formatted(.dateTime.month(.abbreviated).day())): \(hours(week.hours))"
            )
        }
    }

    private func monthColumns(_ months: [UsageSlot]) -> [SlotColumn] {
        months.map { month in
            SlotColumn(
                value: month.hours,
                label: month.date.formatted(.dateTime.month(.abbreviated)),
                tooltip: "\(month.date.formatted(Self.monthFormat)): \(hours(month.hours))"
            )
        }
    }

    /// Thinned out once the months stop fitting, counting back so the latest keeps its label.
    private func totalColumns(_ totals: [UsageSlot]) -> [SlotColumn] {
        let every = totals.count <= Self.monthsShown + 2 ? 1 : 3
        return totals.enumerated().map { index, month in
            let isLabeled = (totals.count - 1 - index) % every == 0
            return SlotColumn(
                value: month.hours,
                label: isLabeled ? month.date.formatted(.dateTime.month(.abbreviated)) : nil,
                tooltip: "Total by \(month.date.formatted(Self.monthFormat)): \(hours(month.hours))"
            )
        }
    }
}
