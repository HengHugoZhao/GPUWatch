import GPUWatchCore
import SwiftUI

/// How many jobs the user submitted this week, month and year, each over its own time scale.
struct JobActivity: View {
    let history: JobHistory

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("Jobs I submitted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 24) {
                    tile("this week", slots: history.week(), scale: .week)
                    tile("this month", slots: history.month(), scale: .month)
                    tile("this year", slots: history.year(), scale: .year)
                }
            }
            .padding(14)
        }
    }

    private func tile(_ period: String, slots: [ActivitySlot], scale: ActivityScale) -> some View {
        let total = slots.map(\.count).reduce(0, +)
        return SlotTile(
            number: "\(total)",
            caption: "\(total == 1 ? "job" : "jobs") \(period)",
            columns: slots.map { slot in
                SlotColumn(
                    value: Double(slot.count),
                    label: scale.isLabeled(slot.date) ? slot.date.formatted(scale.labelFormat) : nil,
                    tooltip: "\(slot.date.formatted(scale.nameFormat)): \(slot.count == 1 ? "1 job" : "\(slot.count) jobs")"
                )
            }
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

/// The user's GPU hours on one machine: per week, per month, and in total.
struct GPUHoursPanel: View {
    let usage: GPUUsage
    let today: Date
    /// Where the numbers come from, which differs by machine.
    let note: String

    private static let weeksShown = 12
    private static let monthsShown = 12
    private static let weekLabelEvery = 4
    private static let monthFormat = Date.FormatStyle().month(.wide).year()

    var body: some View {
        let weeks = usage.weeks(count: Self.weeksShown, through: today)
        let months = usage.months(count: Self.monthsShown, through: today)
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("My GPU hours")
                    Spacer(minLength: 0)
                    Text(note)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                HStack(alignment: .top, spacing: 24) {
                    SlotTile(number: Format.hours(weeks.last?.hours ?? 0), caption: "this week", columns: weekColumns(weeks))
                    SlotTile(number: Format.hours(months.last?.hours ?? 0), caption: "this month", columns: monthColumns(months))
                    SlotTile(number: Format.hours(usage.totalHours), caption: "total", columns: totalColumns())
                }
            }
            .padding(14)
        }
    }

    private func hours(_ value: Double) -> String {
        "\(Format.hours(value)) GPU \(value == 1 ? "hour" : "hours")"
    }

    /// Counted in from the right edge, where a whole date wouldn't fit under the last column.
    private func weekColumns(_ weeks: [UsageSlot]) -> [SlotColumn] {
        weeks.enumerated().map { index, week in
            let isLabeled = (weeks.count - 2 - index) % Self.weekLabelEvery == 0
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
                label: month.date.formatted(.dateTime.month(.narrow)),
                tooltip: "\(month.date.formatted(Self.monthFormat)): \(hours(month.hours))"
            )
        }
    }

    /// Thinned out once the months stop fitting, counting back so the latest keeps its label.
    private func totalColumns() -> [SlotColumn] {
        let totals = usage.runningTotal(through: today, minimumMonths: Self.monthsShown)
        let every = totals.count <= Self.monthsShown + 2 ? 1 : 3
        return totals.enumerated().map { index, month in
            let isLabeled = (totals.count - 1 - index) % every == 0
            return SlotColumn(
                value: month.hours,
                label: isLabeled ? month.date.formatted(.dateTime.month(every == 1 ? .narrow : .abbreviated)) : nil,
                tooltip: "Total by \(month.date.formatted(Self.monthFormat)): \(hours(month.hours))"
            )
        }
    }
}
