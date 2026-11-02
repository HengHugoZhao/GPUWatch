import Charts
import SwiftUI

/// One column of a `SlotChart`.
struct SlotColumn {
    let value: Double
    /// Under the column. Leave it nil where there isn't room for every column to have one.
    let label: String?
    /// Shown only while the pointer is on the column.
    let tooltip: String
}

/// A headline number over the chart of what makes it up.
struct SlotTile: View {
    let number: String
    let caption: String
    let columns: [SlotColumn]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number)
                    .font(.system(size: 28, weight: .semibold))
                    .lineLimit(1)
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            SlotChart(columns: columns)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Columns with no numbers until the pointer is on one. Slots are categories rather than dates,
/// which centers each label under its column.
struct SlotChart: View {
    let columns: [SlotColumn]

    /// `State` as a plain stored value: the `@State` macro's plugin isn't in the Command Line Tools.
    private let hoveredSlot = State<String?>(initialValue: nil)

    /// Room above the tallest column, for the tooltip.
    private static let headroom = 1.5
    /// One job in a month beside 88 in another still has to be visible.
    private static let minimumHeight = 0.03

    private func category(_ index: Int) -> String { "\(index)" }

    var body: some View {
        let hovered = hoveredSlot.wrappedValue
        let peak = max(columns.map(\.value).max() ?? 0, 1)
        Chart {
            if let hovered, let column = Int(hovered).flatMap({ columns.indices.contains($0) ? columns[$0] : nil }) {
                RectangleMark(x: .value("When", hovered), width: .ratio(1))
                    .foregroundStyle(Color.primary.opacity(0.06))
                    .annotation(
                        position: .top,
                        spacing: 0,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        Text(column.tooltip)
                            .font(.caption)
                            .monospacedDigit()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
            }
            RuleMark(y: .value("Baseline", 0))
                .foregroundStyle(Color.primary.opacity(0.15))
                .lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(columns.indices, id: \.self) { index in
                if columns[index].value > 0 {
                    BarMark(
                        x: .value("When", category(index)),
                        y: .value("Amount", max(columns[index].value, peak * Self.minimumHeight)),
                        width: .ratio(0.7)
                    )
                    .foregroundStyle(Theme.meter)
                    .opacity(hovered == nil || hovered == category(index) ? 1 : 0.4)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2))
                    .accessibilityLabel(columns[index].tooltip)
                }
            }
        }
        .chartXScale(domain: columns.indices.map(category))
        .chartYScale(domain: 0...(peak * Self.headroom))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: columns.indices.filter { columns[$0].label != nil }.map(category)) { value in
                AxisValueLabel {
                    if let index = value.as(String.self).flatMap({ Int($0) }), let label = columns[index].label {
                        Text(label).font(.caption)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        hoveredSlot.wrappedValue = slot(at: phase, proxy: proxy, geometry: geometry)
                    }
            }
        }
        .frame(height: 84)
    }

    private func slot(at phase: HoverPhase, proxy: ChartProxy, geometry: GeometryProxy) -> String? {
        guard case .active(let location) = phase, let plot = proxy.plotFrame else { return nil }
        let frame = geometry[plot]
        guard frame.contains(location) else { return nil }
        return proxy.value(atX: location.x - frame.origin.x, as: String.self)
    }
}
