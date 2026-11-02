import Charts
import GPUWatchCore
import SwiftUI

/// Charges per day, because a total can't show when the SUs went. Columns rather than a line,
/// since each day is its own amount and most days have none. Amounts appear only under the pointer.
struct ChargesChart: View {
    let charges: MyCharges
    @Binding var hoveredDay: Date?

    /// Room above the tallest column for the tooltip.
    private static let headroom = 1.2
    /// A day with 22 SUs beside one with 4,688 still has to be visible.
    private static let minimumHeight = 0.015

    var body: some View {
        let hovered = hoveredDay
        let peak = Double(charges.busiestDay?.total ?? 0)
        Chart {
            if let hovered {
                RectangleMark(x: .value("Day", hovered, unit: .day), width: .ratio(1))
                    .foregroundStyle(Color.primary.opacity(0.06))
                    .annotation(
                        position: .top,
                        spacing: 0,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        tooltip(for: hovered)
                    }
            }
            RuleMark(y: .value("Baseline", 0))
                .foregroundStyle(Color.primary.opacity(0.15))
                .lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(charges.days.filter { $0.total > 0 }) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("SUs", max(Double(day.total), peak * Self.minimumHeight)),
                    width: .ratio(0.8)
                )
                .foregroundStyle(Theme.meter)
                .opacity(hovered == nil || hovered == day.date ? 1 : 0.4)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2))
                .accessibilityLabel(day.date.formatted(ChargesHistory.dayFormat))
                .accessibilityValue("\(Format.credits(day.total)) SUs")
            }
        }
        .chartXScale(domain: charges.firstDay...dayAfter(charges.lastDay))
        .chartYScale(domain: 0...(peak * Self.headroom))
        .chartXAxis {
            AxisMarks(values: ticks) { _ in
                AxisValueLabel(format: ChargesHistory.dayFormat)
                    .font(.caption)
            }
        }
        .chartYAxis(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        hoveredDay = day(at: phase, proxy: proxy, geometry: geometry)
                    }
            }
        }
        .frame(height: ChargesHeatmap.height)
    }

    private func tooltip(for date: Date) -> some View {
        Text(charges.summary(of: date))
            .font(.caption)
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    /// The 1st and 15th of each month in the window.
    private var ticks: [Date] {
        var ticks: [Date] = []
        var date = charges.firstDay
        while date <= charges.lastDay {
            if [1, 15].contains(Calendar.current.component(.day, from: date)) { ticks.append(date) }
            date = dayAfter(date)
        }
        return ticks
    }

    private func dayAfter(_ date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
    }

    private func day(at phase: HoverPhase, proxy: ChartProxy, geometry: GeometryProxy) -> Date? {
        guard case .active(let location) = phase, let plot = proxy.plotFrame else { return nil }
        let frame = geometry[plot]
        guard frame.contains(location), let date: Date = proxy.value(atX: location.x - frame.origin.x) else { return nil }
        let day = Calendar.current.startOfDay(for: date)
        return day >= charges.firstDay && day <= charges.lastDay ? day : nil
    }
}
