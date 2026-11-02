import Foundation

/// A storage location to report on.
public struct StorageTarget: Sendable {
    /// The path as people know it, which is what the app shows.
    public let path: String
    /// Where `hdquota` lists it, for a path that's a link to somewhere else.
    let quotaLocation: String
    /// What the numbers cover, which a path alone doesn't say.
    let note: String

    init(path: String, quotaLocation: String? = nil, note: String) {
        self.path = path
        self.quotaLocation = quotaLocation ?? path
        self.note = note
    }
}

public struct StorageUsage: Identifiable, Sendable, Equatable {
    public let path: String
    public let note: String
    public let totalMB: Int
    public let usedMB: Int

    public var id: String { path }

    init(target: StorageTarget, totalMB: Int, usedMB: Int) {
        self.path = target.path
        self.note = target.note
        self.totalMB = totalMB
        self.usedMB = usedMB
    }

    /// Reads `df -B1 --output=size,used`: a header line, then two byte counts.
    init?(target: StorageTarget, dfLines lines: [String]) {
        let bytesInMB = 1024 * 1024
        for line in lines {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, let size = Int(fields[0]), let used = Int(fields[1]), size > 0 else { continue }
            self.init(target: target, totalMB: size / bytesInMB, usedMB: used / bytesInMB)
            return
        }
        return nil
    }

    /// Picks the targets out of an `hdquota` report. It skips a location it can't read and
    /// still exits 0, so a target missing from the report counts as an error too.
    static func fromQuotaReport(_ section: RemoteOutput.Section?, targets: [StorageTarget]) -> (usage: [StorageUsage], error: String?) {
        var sizes: [String: (total: Int, used: Int)] = [:]
        for line in section?.lines ?? [] {
            if let row = parseQuotaLine(line), sizes[row.location] == nil {
                sizes[row.location] = (row.total, row.used)
            }
        }
        let usage = targets.compactMap { target in
            sizes[target.quotaLocation].map { StorageUsage(target: target, totalMB: $0.total, usedMB: $0.used) }
        }
        let missing = targets.filter { sizes[$0.quotaLocation] == nil }.map(\.quotaLocation)
        let error = section?.failureMessage ?? (missing.isEmpty ? nil : "Not reported for \(missing.joined(separator: ", "))")
        return (usage, error)
    }

    /// `Research Standard  /standard/takolab  10.0 TB  7.3 TB  2.7 TB  73%`. The first column
    /// can hold spaces, so the location is what anchors the rest. Its "TB" is 2^40 bytes.
    static func parseQuotaLine(_ line: String) -> (location: String, total: Int, used: Int)? {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let start = tokens.firstIndex(where: { $0.hasPrefix("/") }), tokens.count >= start + 5,
              let total = megabytes(tokens[start + 1], unit: tokens[start + 2]), total > 0,
              let used = megabytes(tokens[start + 3], unit: tokens[start + 4])
        else { return nil }
        return (tokens[start], total, used)
    }

    private static func megabytes(_ value: String, unit: String) -> Int? {
        let scales: [String: Double] = ["KB": 1.0 / 1024, "MB": 1, "GB": 1024, "TB": 1024 * 1024, "PB": 1024 * 1024 * 1024]
        guard let number = Double(value), let scale = scales[unit] else { return nil }
        return Int((number * scale).rounded())
    }
}
