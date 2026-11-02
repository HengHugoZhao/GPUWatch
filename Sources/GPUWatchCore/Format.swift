import Foundation

public enum Format {
    /// "3d 2h", "5h 12m", "12m", "45s": the two largest units are plenty.
    public static func duration(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        let (days, hours, minutes) = (s / 86_400, s % 86_400 / 3600, s % 3600 / 60)
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return minutes > 0 ? "\(minutes)m" : "\(s)s"
    }

    public static func gib(mib: Int) -> String {
        String(format: "%.1f", Double(mib) / 1024)
    }

    /// Whole numbers once it's big enough that a decimal is noise: "2.4", "251".
    public static func compactGiB(mb: Int) -> String {
        let value = Double(mb) / 1024
        return value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
    }

    /// A size with its unit, moving up to TiB when GiB gets unwieldy: "54 GiB", "1.5 TiB".
    public static func memory(mb: Int) -> String {
        if mb >= tibInMB { return String(format: "%.1f TiB", Double(mb) / Double(tibInMB)) }
        return "\(compactGiB(mb: mb)) GiB"
    }

    /// Two sizes sharing the total's unit, for tight columns: "13.2 / 28.6 TiB", "620 / 750 GiB".
    public static func memoryPair(usedMB: Int, totalMB: Int) -> String {
        if totalMB >= tibInMB {
            let scale = Double(tibInMB)
            return String(format: "%.1f / %.1f TiB", Double(usedMB) / scale, Double(totalMB) / scale)
        }
        return "\(compactGiB(mb: usedMB)) / \(compactGiB(mb: totalMB)) GiB"
    }

    private static let tibInMB = 1024 * 1024

    /// A core count from CPU time, so usually fractional: "3.9 cores", "1.0 core".
    public static func cores(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text == "1.0" ? "1.0 core" : "\(text) cores"
    }

    /// Service units in full, since a small charge has to show: "9,887,961".
    public static func credits(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    /// GPU hours, with a decimal only while it's small: "6,075", "3.5".
    public static func hours(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value < 10 ? 0...1 : 0...0)).locale(Locale(identifier: "en_US")))
    }

    /// An SU rate, which can be fractional: "1.6", "1,468.0".
    public static func creditRate(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US")))
    }

    /// "14.1%", but never rounding some use down to nothing or none up to something.
    public static func percent(_ fraction: Double) -> String {
        if fraction <= 0 { return "0%" }
        if fraction < 0.001 { return "<0.1%" }
        return String(format: "%.1f%%", fraction * 100)
    }

    /// A calendar date read by `AllocationGrant.day`: "Sep 24, 2027".
    public static func day(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Locale(identifier: "en_US"), timeZone: .gmt))
    }

    public static func relative(_ date: Date, now: Date) -> String {
        let delta = Int(date.timeIntervalSince(now))
        if abs(delta) < 60 { return delta >= 0 ? "any moment" : "just now" }
        return delta > 0 ? "in \(duration(delta))" : "\(duration(-delta)) ago"
    }

    public static func absolute(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
