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

/// One period of a `HistoryPanel`: its total as a tab, and the columns that make it up.
struct HistoryTab {
    let caption: String
    let number: String
    let unit: String
    let columns: [SlotColumn]
    /// The column holding today, drawn brightest. Nil when none does.
    let current: Int?
}

/// A history in one chart: each period's total is a tab, and the chart below shows the selected one.
/// One wide chart rather than four small ones, so each period has room for its detail and a scale.
struct HistoryPanel: View {
    let title: String
    let note: String?
    let tabs: [HistoryTab]
    /// Remembered per panel, so the chart opens on the period last looked at.
    @AppStorage private var selected: Int

    init(title: String, note: String?, storageKey: String, tabs: [HistoryTab]) {
        self.title = title
        self.note = note
        self.tabs = tabs
        _selected = AppStorage(wrappedValue: 0, storageKey)
    }

    var body: some View {
        let index = tabs.indices.contains(selected) ? selected : 0
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title).eyebrow()
                    Spacer(minLength: 0)
                    if let note { Text(note).font(.caption) }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
                HStack(spacing: 4) {
                    ForEach(tabs.indices, id: \.self) { tabIndex in
                        tab(tabIndex, isSelected: tabIndex == index)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                if tabs.indices.contains(index) {
                    SlotChart(columns: tabs[index].columns, current: tabs[index].current)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 8)
                        .id(index)
                }
            }
        }
    }

    /// The selected period is an inset pill in the accent's tint, like a segmented control.
    private func tab(_ tabIndex: Int, isSelected: Bool) -> some View {
        let tab = tabs[tabIndex]
        let shape = RoundedRectangle(cornerRadius: 7)
        return Button {
            selected = tabIndex
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(tab.caption)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(tab.number)
                        .display(14)
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    Text(tab.unit)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(minWidth: 96, alignment: .leading)
            .background(isSelected ? Theme.accentSoft : Color.clear, in: shape)
            .overlay {
                if isSelected { shape.strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1) }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel("\(tab.caption): \(tab.number) \(tab.unit)")
    }
}

/// Columns over a light scale, the current one brightest. Exact amounts appear under the pointer.
/// Slots are categories rather than dates, which centers each label under its column.
struct SlotChart: View {
    let columns: [SlotColumn]
    var current: Int?

    /// `State` as a plain stored value: the `@State` macro's plugin isn't in the Command Line Tools.
    private let hoveredSlot = State<String?>(initialValue: nil)

    private static let height: CGFloat = 92
    /// Room above the tallest column.
    private static let headroom = 1.15
    /// One job in a month beside 88 in another still has to be visible.
    private static let minimumHeight = 0.02
    /// Columns other than the current one, so today's stands out without hiding the rest.
    private static let pastOpacity = 0.55

    private func category(_ index: Int) -> String { "\(index)" }

    /// Few columns get narrow bars, so a week doesn't turn into slabs.
    private var barRatio: Double {
        columns.count <= 8 ? 0.3 : columns.count <= 14 ? 0.5 : 0.65
    }

    var body: some View {
        let hovered = hoveredSlot.wrappedValue
        let peak = max(columns.map(\.value).max() ?? 0, 1)
        Chart {
            if let hovered {
                RectangleMark(x: .value("When", hovered), width: .ratio(1))
                    .foregroundStyle(Color.primary.opacity(0.06))
            }
            ForEach(columns.indices, id: \.self) { index in
                if columns[index].value > 0 {
                    BarMark(
                        x: .value("When", category(index)),
                        y: .value("Amount", max(columns[index].value, peak * Self.minimumHeight)),
                        width: .ratio(barRatio)
                    )
                    .foregroundStyle(Theme.accent)
                    .opacity(opacity(index, hovered: hovered))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3))
                    .accessibilityLabel(columns[index].tooltip)
                }
            }
            RuleMark(y: .value("Baseline", 0))
                .foregroundStyle(Color.primary.opacity(0.2))
                .lineStyle(StrokeStyle(lineWidth: 1))
            // Last, so the tooltip draws over the columns rather than behind them.
            if let hovered, let column = Int(hovered).flatMap({ columns.indices.contains($0) ? columns[$0] : nil }) {
                RuleMark(x: .value("When", hovered))
                    .foregroundStyle(.clear)
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
                            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline, lineWidth: 1) }
                            .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
                    }
            }
        }
        .chartXScale(domain: columns.indices.map(category))
        .chartYScale(domain: 0...(peak * Self.headroom))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .foregroundStyle(Color.primary.opacity(0.12))
                AxisValueLabel {
                    if let amount = value.as(Double.self), amount > 0 {
                        Text(Self.short(amount))
                            .font(.caption2)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: columns.indices.filter { columns[$0].label != nil }.map(category)) { value in
                AxisValueLabel {
                    if let index = value.as(String.self).flatMap({ Int($0) }), let label = columns[index].label {
                        Text(label)
                            .font(.caption)
                            .fontWeight(index == current ? .semibold : .regular)
                            .fixedSize()
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
        .frame(height: Self.height)
    }

    private func opacity(_ index: Int, hovered: String?) -> Double {
        if let hovered { return hovered == category(index) ? 1 : 0.3 }
        return current == nil || index == current ? 1 : Self.pastOpacity
    }

    /// Scale labels: "1.2k" rather than "1,200", and no decimals once past 10.
    private static func short(_ value: Double) -> String {
        if value >= 1000 { return String(format: value >= 10_000 ? "%.0fk" : "%.1fk", value / 1000) }
        if value >= 10 || value == value.rounded() { return "\(Int(value.rounded()))" }
        return String(format: "%.1f", value)
    }

    private func slot(at phase: HoverPhase, proxy: ChartProxy, geometry: GeometryProxy) -> String? {
        guard case .active(let location) = phase, let plot = proxy.plotFrame else { return nil }
        let frame = geometry[plot]
        guard frame.contains(location) else { return nil }
        return proxy.value(atX: location.x - frame.origin.x, as: String.self)
    }
}
