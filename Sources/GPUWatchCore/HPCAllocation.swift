import Foundation

public enum GrantPhase: Sendable, Equatable {
    case active, expired, inactive
}

/// One award of service units (SUs) to the lab, with its own balance and dates.
public struct AllocationGrant: Identifiable, Sendable, Equatable {
    public let id: Int
    public let description: String
    public let starts: Date?
    public let ends: Date?
    public let allocated: Int
    public let remaining: Int
    public let isActive: Bool

    public var used: Int { max(allocated - remaining, 0) }
    public var usedFraction: Double { allocated > 0 ? Double(used) / Double(allocated) : 0 }

    public func phase(now: Date) -> GrantPhase {
        if isActive { return .active }
        if let ends, ends < now { return .expired }
        return .inactive
    }

    /// Parses one row of `mam-list-allocations --format csv`, in `RemoteScripts.allocationFields`
    /// order. Returns nil for the header, or for anything else that isn't a grant.
    /// The description goes last because it's free text: it can be empty, or quoted with commas.
    init?(csvLine line: String) {
        let fields = line.split(separator: ",", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 7, let id = Int(fields[0]),
              let allocated = Double(fields[3]), let remaining = Double(fields[4])
        else { return nil }
        self.id = id
        self.starts = Self.day(fields[1])
        self.ends = Self.day(fields[2])
        self.allocated = Int(allocated.rounded())
        self.remaining = Int(remaining.rounded())
        self.isActive = fields[5] == "True"
        self.description = Self.unquoted(fields[6])
    }

    /// Grants run between calendar dates, so these are read and shown in UTC to keep the
    /// date from shifting with the Mac's time zone. An open-ended grant says `infinity`.
    static func day(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(text.prefix(10)))
    }

    private static func unquoted(_ field: String) -> String {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return trimmed }
        return trimmed.dropFirst().dropLast().replacingOccurrences(of: "\"\"", with: "\"")
    }
}

/// Every grant on the lab's account.
public struct LabAllocation: Sendable {
    public let account: String
    /// Active grants first, soonest to end on top; then the rest, most recent first.
    public let grants: [AllocationGrant]

    public var activeGrants: [AllocationGrant] { grants.filter(\.isActive) }
    public var inactiveGrants: [AllocationGrant] { grants.filter { !$0.isActive } }

    init(account: String, grants: [AllocationGrant]) {
        self.account = account
        self.grants = grants.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            let (aEnd, bEnd) = (a.ends ?? .distantFuture, b.ends ?? .distantFuture)
            if aEnd != bEnd { return a.isActive ? aEnd < bEnd : aEnd > bEnd }
            return a.id < b.id
        }
    }
}
