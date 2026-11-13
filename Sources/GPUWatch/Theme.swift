import AppKit
import GPUWatchCore
import SwiftUI

extension Color {
    fileprivate init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }

    fileprivate static func adaptive(light: UInt32, dark: UInt32) -> Color {
        adaptive(light: light, lightAlpha: 1, dark: dark, darkAlpha: 1)
    }

    fileprivate static func adaptive(light: UInt32, lightAlpha: CGFloat, dark: UInt32, darkAlpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark).withAlphaComponent(darkAlpha)
                : NSColor(hex: light).withAlphaComponent(lightAlpha)
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
    // Surfaces and type after Linear's design language: a canvas, panels one step up it with
    // hairline borders, and one lavender accent kept for selection, focus and the main action.
    // Linear documents only its dark mode; the light steps keep the same ladder.

    /// Laid over the glass so the desktop shows through as colour, not as detail.
    static let canvasTint = Color.adaptive(light: 0xF4F4F7, lightAlpha: 0.62, dark: 0x111216, darkAlpha: 0.62)

    // The page is the desktop seen through frosted glass, so panels are tints over it rather than
    // solid fills: a milky white in light mode, a faint lift in dark.
    static let surface = Color.adaptive(light: 0xFFFFFF, lightAlpha: 0.62, dark: 0xFFFFFF, darkAlpha: 0.055)
    /// A hovered row, or a card that isn't selected.
    static let surfaceRaised = Color.adaptive(light: 0xFFFFFF, lightAlpha: 0.85, dark: 0xFFFFFF, darkAlpha: 0.09)
    static let hairline = Color.adaptive(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.08)
    static let hairlineStrong = Color.adaptive(light: 0x000000, lightAlpha: 0.14, dark: 0xFFFFFF, darkAlpha: 0.14)
    /// Panels catch a faint light along their top edge.
    static let edgeHighlight = Color.adaptive(light: 0xFFFFFF, lightAlpha: 0.9, dark: 0xFFFFFF, darkAlpha: 0.16)

    static let accent = Color.adaptive(light: 0x5B5BF6, dark: 0x8287FF)
    static let accentSoft = Color.adaptive(light: 0xE8E8FE, dark: 0x262760)

    static let radius: CGFloat = 12
    static let smallRadius: CGFloat = 8

    static let good = Color.adaptive(light: 0x16A34A, dark: 0x34D27A)
    static let warning = Color.adaptive(light: 0xF59E0B, dark: 0xFBBF24)
    static let serious = Color.adaptive(light: 0xF97316, dark: 0xFF8B3D)
    static let critical = Color.adaptive(light: 0xE5484D, dark: 0xFF6369)

    static let meter = accent
    static let meterTrack = Color.adaptive(light: 0x5B5BF6, lightAlpha: 0.13, dark: 0x8287FF, darkAlpha: 0.18)

    static let time = Color.adaptive(light: 0x8C9A00, dark: 0xB6E62E)
    static let timeTrack = Color.adaptive(light: 0xECEFC2, dark: 0x36431A)

    static let stranded = Color(hex: 0x898781)
    static let inUse = Color.adaptive(light: 0xC3C2B7, dark: 0x52514E)
    static let barTrack = Color.adaptive(light: 0xEDECE6, dark: 0x2C2C2A)
}

/// The window's backdrop: whatever is behind it, blurred, like the sidebar.
struct Glass: NSViewRepresentable {
    /// The see-through one: the windows and wallpaper behind tint the page, not just its brightness.
    var material: NSVisualEffectView.Material = .fullScreenUI

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
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
                    let width = max(geometry.size.width * min(fraction, 1), 4)
                    Capsule()
                        .fill(Theme.meter)
                        .frame(width: width)
                }
            }
        }
        .frame(height: height)
        // Glides between readings, which arrive every second while utilization streams.
        .animation(.easeOut(duration: 0.5), value: fraction)
        .accessibilityValue("\(Int((min(max(fraction, 0), 1)) * 100)) percent")
    }
}

/// One share of a whole as an arc, for a number that stands alone, like how busy a GPU is.
/// Starts at 12 o'clock and runs clockwise, on its own track.
struct Ring: View {
    let fraction: Double?
    var lineWidth: CGFloat = 6

    var body: some View {
        ZStack {
            Circle().stroke(Theme.meterTrack, lineWidth: lineWidth)
            if let fraction, fraction > 0 {
                Circle()
                    .trim(from: 0, to: max(min(fraction, 1), 0.02))
                    .stroke(Theme.meter, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(lineWidth / 2)
        .animation(.easeOut(duration: 0.5), value: fraction)
        .accessibilityValue(fraction.map { "\(Int(min(max($0, 0), 1) * 100)) percent" } ?? "No reading")
    }
}

/// A headline number on its own panel, with what it counts beneath and, optionally, its bar.
struct StatTile<Visual: View>: View {
    let title: String
    let value: String
    let caption: String
    @ViewBuilder var visual: Visual

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .eyebrow()
                .foregroundStyle(.secondary)
            Text(value)
                .display(26)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            visual
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
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

/// A job's state as a dot, for a card whose right side already says what's going on. The word is
/// in its tooltip and its accessibility label, so the colour isn't the only signal.
struct StatusDot: View {
    let status: StatusLabel

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 8, height: 8)
            .background(Circle().fill(status.color.opacity(0.25)).frame(width: 14, height: 14))
            .frame(width: 14, height: 14)
            .help(status.text)
            .accessibilityLabel(status.text)
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

/// Display type pulls its tracking in as it grows, as Linear's does; small labels open it up.
extension Text {
    func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Text {
        font(.system(size: size, weight: weight)).tracking(-size * 0.025)
    }

    /// A small label naming what's below it, like a column heading or a panel's title.
    func eyebrow() -> Text {
        font(.caption.weight(.medium)).tracking(0.3)
    }
}

struct SectionHeader: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).display(20)
            if let detail {
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }
}

/// A small pill beside a name, in the accent: Linear's status badge.
struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Theme.accentSoft, in: Capsule())
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

/// One storage location: how full it is as a ring, the amounts beside it, and a warning near the top.
struct StorageCard: View {
    let storage: StorageUsage

    private static let ringSize: CGFloat = 64
    private static let almostFull = 0.9

    private var fraction: Double { storage.totalMB > 0 ? Double(storage.usedMB) / Double(storage.totalMB) : 0 }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Ring(fraction: fraction, lineWidth: 7)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(width: Self.ringSize, height: Self.ringSize)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(Theme.accent)
                    Text(storage.path)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Text("\(Format.memory(mb: storage.usedMB)) of \(Format.memory(mb: storage.totalMB)) used")
                    .font(.callout)
                    .monospacedDigit()
                HStack(spacing: 8) {
                    Text("\(Format.memory(mb: max(storage.totalMB - storage.usedMB, 0))) free")
                        .foregroundStyle(.secondary)
                    if fraction >= Self.almostFull {
                        StatusLabel(symbol: "exclamationmark.triangle.fill", color: Theme.serious, text: "Almost full")
                    }
                }
                .font(.caption)
                .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: 380, alignment: .leading)
        .surface()
        .help(storage.note)
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
            HStack(alignment: .top, spacing: 12) {
                ForEach(storage) { StorageCard(storage: $0) }
            }
        }
    }
}

/// A bordered surface for table-like content.
struct Panel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .surface()
    }
}

extension View {
    /// A panel's lift off the canvas: its own surface, a hairline, and in dark mode a lit top edge.
    func surface(_ fill: Color = Theme.surface, border: Color = Theme.hairline, radius: CGFloat = Theme.radius) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        return background(fill, in: shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [Theme.edgeHighlight, border], startPoint: .top, endPoint: .init(x: 0.5, y: 0.08)),
                    lineWidth: 1
                )
            }
            .clipShape(shape)
    }
}

/// A list of jobs that takes only the height it needs, and scrolls once that passes `maxHeight`.
/// A plain `ScrollView` inside the page's own has no height of its own to go by, so this measures.
struct CappedScroll<Content: View>: View {
    var isCapped = true
    /// By default a bit under four job rows with bars, so a row cut off at the bottom shows there's more.
    var maxHeight: CGFloat = 290
    @ViewBuilder let content: Content
    /// `State` as a plain stored value: the `@State` macro's plugin isn't in the Command Line Tools.
    private let height = State(initialValue: CGFloat(0))

    var body: some View {
        if isCapped {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content }
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { height.wrappedValue = $0 }
            }
            .frame(height: min(height.wrappedValue, maxHeight))
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
            .background(isHovered.wrappedValue ? Theme.surfaceRaised : Color.clear)
            .onHover { isHovered.wrappedValue = $0 }
    }
}
