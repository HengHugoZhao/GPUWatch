import AppKit
import GPUWatchCore
import SwiftUI

extension Color {
    fileprivate init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }

    fileprivate static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }
}

extension NSColor {
    fileprivate convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Status colors mean state and always ride next to an icon or a label. Neutrals carry the
/// parts of a bar nobody needs to act on, so free GPUs are the only loud thing on the page.
enum Theme {
    static let good = Color(hex: 0x0CA30C)
    static let warning = Color(hex: 0xFAB219)
    static let serious = Color(hex: 0xEC835A)
    static let critical = Color(hex: 0xD03B3B)

    static let meter = Color.adaptive(light: 0x2A78D6, dark: 0x3987E5)
    static let meterTrack = Color.adaptive(light: 0xCDE2FB, dark: 0x0D366B)

    static let time = Color.adaptive(light: 0x8C9A00, dark: 0xB6E62E)
    static let timeTrack = Color.adaptive(light: 0xECEFC2, dark: 0x36431A)

    static let stranded = Color(hex: 0x898781)
    static let inUse = Color.adaptive(light: 0xC3C2B7, dark: 0x52514E)
    static let barTrack = Color.adaptive(light: 0xEDECE6, dark: 0x2C2C2A)

    /// The heatmap's levels, least to most. One hue, stronger against the surface in either mode.
    static let heat = [
        Color.adaptive(light: 0x88B6F1, dark: 0x1B4F8A),
        Color.adaptive(light: 0x65A1EB, dark: 0x2161A8),
        Color.adaptive(light: 0x438CE2, dark: 0x2A74C6),
        Color.adaptive(light: 0x2A6FC4, dark: 0x66A9F2),
        Color.adaptive(light: 0x124F9E, dark: 0xA8CFFA),
    ]
}

/// One value out of a whole: memory used, GPU busy.
struct Meter: View {
    let fraction: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.meterTrack)
                if fraction > 0 {
                    Capsule()
                        .fill(Theme.meter)
                        .frame(width: max(geometry.size.width * min(fraction, 1), 4))
                }
            }
        }
        .frame(height: height)
        .accessibilityValue("\(Int((min(max(fraction, 0), 1)) * 100)) percent")
    }
}

/// How much of a job's time limit has gone: short, in blocks and its own color, so it doesn't
/// read as one more of the usage bars beside it.
struct TimeMeter: View {
    let fraction: Double

    private static let blocks = 8
    private static let width: CGFloat = 64
    private static let height: CGFloat = 6
    private static let sliver: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Theme.timeTrack
                if fraction > 0 {
                    Theme.time.frame(width: max(geometry.size.width * min(fraction, 1), Self.sliver))
                }
            }
        }
        .mask {
            HStack(spacing: 2) {
                ForEach(0..<Self.blocks, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1.5)
                }
            }
        }
        .frame(width: Self.width, height: Self.height)
        .accessibilityValue("\(Int((min(max(fraction, 0), 1)) * 100)) percent")
    }
}

/// A pool of GPUs split by what a new job could do with them. Offline GPUs are left
/// as bare track: they aren't anything you can use, or anything anyone is using.
struct GPUBar: View {
    private struct Part: Identifiable {
        let id: String
        let count: Int
        let color: Color
    }

    let counts: GPUCounts

    private static let gap: CGFloat = 2
    /// One free GPU in a pool of 128 still has to be visible.
    private static let minimumWidth: CGFloat = 4

    private var parts: [Part] {
        [
            Part(id: "Ready", count: counts.ready, color: Theme.good),
            Part(id: "Backfill", count: counts.backfill, color: Theme.warning),
            Part(id: "Stranded", count: counts.stranded, color: Theme.stranded),
            Part(id: "In use", count: counts.inUse, color: Theme.inUse),
        ].filter { $0.count > 0 }
    }

    var body: some View {
        GeometryReader { geometry in
            let parts = parts
            let widths = widths(for: parts, in: geometry.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.barTrack)
                HStack(spacing: Self.gap) {
                    ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                        Rectangle()
                            .fill(part.color)
                            .frame(width: widths[index])
                            .help("\(part.id): \(part.count) of \(counts.total) GPUs")
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel(
            "\(counts.ready) ready, \(counts.backfill) backfill, \(counts.stranded) stranded, "
                + "\(counts.inUse) in use, \(counts.offline) offline"
        )
    }

    private func widths(for parts: [Part], in width: CGFloat) -> [CGFloat] {
        guard counts.total > 0, !parts.isEmpty else { return [] }
        let usable = max(width - Self.gap * CGFloat(parts.count - 1), 0)
        var widths = parts.map { max(usable * CGFloat($0.count) / CGFloat(counts.total), Self.minimumWidth) }
        // Whatever the small parts gained comes out of the largest.
        let budget = usable * CGFloat(counts.total - counts.offline) / CGFloat(counts.total)
        let excess = widths.reduce(0, +) - budget
        if excess > 0, let largest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
            widths[largest] = max(widths[largest] - excess, Self.minimumWidth)
        }
        return widths
    }
}

struct Swatch: View {
    let color: Color

    /// The ring is for the Offline swatch: it shows bare track, which nearly matches the page.
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1) }
            .frame(width: 10, height: 10)
    }
}

/// A status is always an icon and a word, never color alone.
struct StatusLabel: View {
    let symbol: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .imageScale(.small)
            Text(text)
        }
    }
}

extension GPUAvailability {
    var status: StatusLabel {
        switch self {
        case .free: return StatusLabel(symbol: "checkmark.circle.fill", color: Theme.good, text: "Free")
        case .partlyFree: return StatusLabel(symbol: "circle.lefthalf.filled", color: Theme.warning, text: "Partly free")
        case .full: return StatusLabel(symbol: "minus.circle.fill", color: Theme.stranded, text: "Full")
        }
    }
}

extension JobPhase {
    var status: StatusLabel {
        let (symbol, color): (String, Color)
        switch self {
        case .running: (symbol, color) = ("play.circle.fill", Theme.good)
        case .pending: (symbol, color) = ("clock.fill", Theme.warning)
        case .completing: (symbol, color) = ("arrow.triangle.2.circlepath", Theme.good)
        case .suspended: (symbol, color) = ("pause.circle.fill", Theme.stranded)
        case .completed: (symbol, color) = ("checkmark.circle.fill", Theme.good)
        case .failed: (symbol, color) = ("xmark.octagon.fill", Theme.critical)
        case .cancelled: (symbol, color) = ("slash.circle", Theme.stranded)
        case .timedOut: (symbol, color) = ("timer", Theme.serious)
        case .outOfMemory: (symbol, color) = ("memorychip", Theme.critical)
        case .nodeFailed: (symbol, color) = ("exclamationmark.triangle.fill", Theme.critical)
        case .preempted: (symbol, color) = ("arrow.uturn.backward.circle", Theme.serious)
        case .other: (symbol, color) = ("questionmark.circle", Theme.stranded)
        }
        return StatusLabel(symbol: symbol, color: color, text: label)
    }
}

extension GrantPhase {
    var status: StatusLabel {
        switch self {
        case .active: return StatusLabel(symbol: "checkmark.circle.fill", color: Theme.good, text: "Active")
        case .expired: return StatusLabel(symbol: "clock", color: Theme.stranded, text: "Expired")
        case .inactive: return StatusLabel(symbol: "pause.circle.fill", color: Theme.stranded, text: "Inactive")
        }
    }
}

struct SectionHeader: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.title2.weight(.semibold))
            if let detail {
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }
}

/// Label and value pairs under an expanded row.
struct DetailGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(rows, id: \.0) { label, value in
                GridRow {
                    Text(label).foregroundStyle(.secondary)
                    Text(value).textSelection(.enabled)
                }
            }
        }
        .font(.caption)
    }
}

/// One part of a machine's answer failed while the rest came through.
struct SectionError: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.serious)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

/// A total and how much of it is taken: CPU memory on a machine or a pool of nodes, or storage.
struct UsageMeter: View {
    let title: String
    let usedMB: Int
    let totalMB: Int
    let usedWord: String
    let remainderWord: String
    let explanation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("\(Format.memory(mb: usedMB)) / \(Format.memory(mb: totalMB)) \(usedWord)")
                Spacer(minLength: 4)
                Text("\(Format.memory(mb: max(totalMB - usedMB, 0))) \(remainderWord)")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .monospacedDigit()
            .lineLimit(1)
            Meter(fraction: totalMB > 0 ? Double(usedMB) / Double(totalMB) : 0)
        }
        .frame(width: 300)
        .help(explanation)
    }
}

extension UsageMeter {
    init(storage: StorageUsage) {
        self.init(
            title: storage.path,
            usedMB: storage.usedMB,
            totalMB: storage.totalMB,
            usedWord: "used",
            remainderWord: "free",
            explanation: storage.note
        )
    }
}

struct StorageSection: View {
    let storage: [StorageUsage]
    let error: String?
    /// Names what failed, in front of the error.
    let errorSource: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Storage", detail: nil)
            if let error {
                SectionError(message: "\(errorSource): \(error)")
            }
            HStack(spacing: 24) {
                ForEach(storage) { UsageMeter(storage: $0) }
            }
        }
    }
}

/// A headline number with a smaller readout beside it, or below it in a narrow window.
struct HeadlineRow<Hero: View, Side: View>: View {
    @ViewBuilder let hero: Hero
    let side: Side

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 24) {
                hero
                Spacer(minLength: 0)
                side
            }
            VStack(alignment: .leading, spacing: 12) {
                hero
                side
            }
        }
    }
}

/// A bordered surface for table-like content.
struct Panel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// A list of jobs that takes only the height it needs, and scrolls once that passes `maxHeight`.
/// A plain `ScrollView` inside the page's own has no height of its own to go by, so this measures.
struct CappedScroll<Content: View>: View {
    /// A bit under four job rows with bars, so a row cut off at the bottom shows there's more.
    private static var maxHeight: CGFloat { 290 }

    var isCapped = true
    @ViewBuilder let content: Content
    /// `State` as a plain stored value: the `@State` macro's plugin isn't in the Command Line Tools.
    private let height = State(initialValue: CGFloat(0))

    var body: some View {
        if isCapped {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content }
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { height.wrappedValue = $0 }
            }
            .frame(height: min(height.wrappedValue, Self.maxHeight))
        } else {
            VStack(alignment: .leading, spacing: 0) { content }
        }
    }
}

/// Turns to point down when open, so expandable rows read the same everywhere.
struct Chevron: View {
    let isOpen: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isOpen ? 90 : 0))
            .frame(width: 12)
    }
}

/// The whole row is the click target and answers to hover.
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverHighlight(content: configuration.label)
    }
}

private struct HoverHighlight<Content: View>: View {
    let content: Content
    /// `State` as a plain stored value: the `@State` macro's plugin isn't in the Command Line Tools.
    private let isHovered = State(initialValue: false)

    var body: some View {
        content
            .contentShape(Rectangle())
            .background(Color.primary.opacity(isHovered.wrappedValue ? 0.04 : 0))
            .onHover { isHovered.wrappedValue = $0 }
    }
}
