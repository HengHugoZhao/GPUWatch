import GPUWatchCore
import SwiftUI

/// The same days two ways: their sizes against each other in the histogram, the weekly shape in
/// the heatmap. Hovering a day in either one highlights it in both and shows its amount.
struct ChargesHistory: View {
    let charges: MyCharges

    /// `State` as a plain stored value: the `@State` macro's plugin isn't in the Command Line Tools.
    private let hoveredDay = State<Date?>(initialValue: nil)

    static let dayFormat = Date.FormatStyle().month(.abbreviated).day()

    /// Under these the heatmap's labels stop fitting, so the two stack instead.
    private static let chartMinWidth: CGFloat = 300
    private static let heatmapMinWidth: CGFloat = 400

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("My SUs per day, last \(RemoteScripts.chargeWindowDays) days, on the day each job ended")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    HeatmapLegend()
                }
                .font(.caption)
                .lineLimit(1)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        chart.frame(minWidth: Self.chartMinWidth, maxWidth: .infinity)
                        heatmap.frame(minWidth: Self.heatmapMinWidth, maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        chart
                        heatmap
                    }
                }
            }
            .padding(14)
        }
    }

    private var chart: some View {
        ChargesChart(charges: charges, hoveredDay: hoveredDay.projectedValue)
    }

    private var heatmap: some View {
        ChargesHeatmap(charges: charges, hoveredDay: hoveredDay.projectedValue)
    }
}

extension MyCharges {
    func summary(of date: Date) -> String {
        let name = date.formatted(ChargesHistory.dayFormat)
        guard let day = day(on: date) else { return "\(name): nothing charged" }
        return "\(name): \(Format.credits(day.total)) SUs, \(day.jobs == 1 ? "1 job" : "\(day.jobs) jobs")"
    }
}

/// SUs per day as a calendar: a column for each week, a row for each weekday, and a stronger
/// color for more SUs. Only a couple of months fit in the window, so the cells stretch to fill it.
struct ChargesHeatmap: View {
    let charges: MyCharges
    @Binding var hoveredDay: Date?

    private static let cellHeight: CGFloat = 24
    private static let headerHeight: CGFloat = 16
    private static let gap: CGFloat = 2
    private static let cornerRadius: CGFloat = 3

    static let height = headerHeight + 7 * (cellHeight + gap)

    var body: some View {
        let weeks = charges.weeks()
        HStack(alignment: .top, spacing: Self.gap) {
            VStack(alignment: .leading, spacing: Self.gap) {
                Color.clear.frame(height: Self.headerHeight)
                ForEach(0..<7, id: \.self) { slot in
                    Text(weekdayLabel(slot))
                        .foregroundStyle(.secondary)
                        .frame(height: Self.cellHeight)
                }
            }
            .padding(.trailing, 6)
            ForEach(weeks.indices, id: \.self) { week in
                VStack(alignment: .leading, spacing: Self.gap) {
                    Text(weekLabel(weeks[week]))
                        .foregroundStyle(.secondary)
                        .frame(height: Self.headerHeight)
                    ForEach(0..<7, id: \.self) { slot in
                        cell(weeks[week][slot])
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .lineLimit(1)
    }

    @ViewBuilder private func cell(_ date: Date?) -> some View {
        if let date {
            let level = charges.day(on: date)?.level ?? 0
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(level > 0 ? Theme.heat[level - 1] : Theme.barTrack)
                .overlay {
                    // The right edge of the window, which otherwise looks like any quiet day.
                    if hoveredDay == date || date == charges.lastDay {
                        RoundedRectangle(cornerRadius: Self.cornerRadius)
                            .strokeBorder(Color.primary.opacity(hoveredDay == date ? 1 : 0.6), lineWidth: 1)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.cellHeight)
                .onHover { isInside in
                    if isInside {
                        hoveredDay = date
                    } else if hoveredDay == date {
                        hoveredDay = nil
                    }
                }
                .accessibilityElement()
                .accessibilityLabel(charges.summary(of: date))
        } else {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: Self.cellHeight)
        }
    }

    /// The first day of the week that's in the window.
    private func weekLabel(_ week: [Date?]) -> String {
        week.compactMap { $0 }.first?.formatted(ChargesHistory.dayFormat) ?? ""
    }

    private func weekdayLabel(_ slot: Int) -> String {
        let calendar = Calendar.current
        return calendar.shortWeekdaySymbols[(calendar.firstWeekday - 1 + slot) % 7]
    }
}

/// The heatmap's colors, in order.
private struct HeatmapLegend: View {
    var body: some View {
        HStack(spacing: 3) {
            Text("Less").foregroundStyle(.secondary).padding(.trailing, 3)
            ForEach(Theme.heat.indices, id: \.self) { Swatch(color: Theme.heat[$0]) }
            Text("More").foregroundStyle(.secondary).padding(.leading, 3)
        }
    }
}
