import Foundation

/// How a pool of GPUs splits by what a new job could actually do with them.
public struct GPUCounts: Sendable, Equatable {
    /// Free on a healthy node with CPU and memory to spare; a job should start right away.
    public var ready = 0
    /// As `ready`, but the scheduler has earmarked the node for a queued job.
    public var backfill = 0
    /// Unallocated, but the node has no CPU or memory left to run a job alongside it.
    public var stranded = 0
    public var inUse = 0
    /// Idle on a node that is down, draining, reserved or in maintenance.
    public var offline = 0

    public init() {}

    public var total: Int { ready + backfill + stranded + inUse + offline }

    public static func + (a: GPUCounts, b: GPUCounts) -> GPUCounts {
        var sum = GPUCounts()
        sum.ready = a.ready + b.ready
        sum.backfill = a.backfill + b.backfill
        sum.stranded = a.stranded + b.stranded
        sum.inUse = a.inUse + b.inUse
        sum.offline = a.offline + b.offline
        return sum
    }
}

public struct HPCNode: Identifiable, Sendable {
    /// The least a GPU job needs alongside the GPU. Matches the 6 GB floor in rivanna_resource.
    public static let minMemoryPerGPUMB = 6144
    /// Listed to everyone, but its nodes are held by reservations rather than open to submit to.
    static let closedPartitions: Set<String> = ["dedicated"]
    /// What one GPU holds, by the names `groupLabel` gives. Slurm doesn't say, so this is by hand:
    /// from UVA's pages, except NVIDIA's specs for the 3090 and 2080 Ti, and a MIG slice's own name.
    /// `rtx_3090` is spelled two ways on the cluster. A type missing here just gets no bar.
    public static let gpuMemoryGB = [
        "1g.24gb": 24, "a100_40gb": 40, "a100_80gb": 80, "a40": 48, "a6000": 48, "b200": 180,
        "rtx3090": 24, "rtx_2080": 11, "rtx_3090": 24, "rtx_pro_6000": 96, "v100": 32,
    ]

    private static let unavailableFlags: Set<String> = [
        "DOWN", "DRAIN", "DRAINING", "DRAINED", "FAIL", "FAILING", "FUTURE", "INVAL", "MAINT", "MAINTENANCE",
        "NOT_RESPONDING", "NO_RESPOND", "POWERED_DOWN", "POWERING_DOWN", "REBOOT_ISSUED", "REBOOT_REQUESTED",
        "RESERVED", "RESV", "UNKNOWN",
    ]

    public let name: String
    public let partitions: [String]
    public let flags: Set<String>
    public let gpuType: String
    public let gpuTotal: Int
    public let gpuAllocated: Int
    public let cpuTotal: Int
    public let cpuAllocated: Int
    public let memoryTotalMB: Int
    public let memoryAllocatedMB: Int
    public let reason: String?

    public var id: String { name }
    public var gpuFree: Int { max(gpuTotal - gpuAllocated, 0) }
    public var cpuFree: Int { max(cpuTotal - cpuAllocated, 0) }
    public var memoryFreeMB: Int { max(memoryTotalMB - memoryAllocatedMB, 0) }
    public var memoryFraction: Double { memoryTotalMB > 0 ? Double(memoryAllocatedMB) / Double(memoryTotalMB) : 0 }
    public var isAvailable: Bool { flags.isDisjoint(with: Self.unavailableFlags) }
    public var isPlanned: Bool { flags.contains("PLANNED") }
    /// Whether this resource is what's keeping some of the node's free GPUs from being used.
    public var cpuLimited: Bool { isAvailable && cpuFree < gpuFree }
    public var memoryLimited: Bool { isAvailable && memoryFreeMB / Self.minMemoryPerGPUMB < gpuFree }

    public var counts: GPUCounts {
        var counts = GPUCounts()
        counts.inUse = min(gpuAllocated, gpuTotal)
        guard isAvailable else {
            counts.offline = gpuFree
            return counts
        }
        let usable = min(gpuFree, cpuFree, memoryFreeMB / Self.minMemoryPerGPUMB)
        counts.stranded = gpuFree - usable
        if isPlanned { counts.backfill = usable } else { counts.ready = usable }
        return counts
    }

    /// The word worth showing beside the node, or nil for a plain healthy node.
    public var stateLabel: String? {
        if flags.contains("DOWN") || flags.contains("NOT_RESPONDING") { return "Down" }
        if flags.contains("MAINTENANCE") || flags.contains("MAINT") { return "Maintenance" }
        if flags.contains("DRAIN") || flags.contains("DRAINING") || flags.contains("DRAINED") { return "Draining" }
        if flags.contains("RESERVED") || flags.contains("RESV") { return "Reserved" }
        if !isAvailable { return "Unavailable" }
        return isPlanned ? "Planned" : nil
    }

    /// Parses one line of `scontrol show node -o`. Returns nil for nodes that are not
    /// open GPU nodes (no GPUs, or only reservation-held or hidden partitions).
    public init?(scontrolLine line: String) {
        var fields: [String: String] = [:]
        for token in line.split(separator: " ") {
            guard let eq = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<eq])
            if fields[key] == nil { fields[key] = String(token[token.index(after: eq)...]) }
        }
        guard let name = fields["NodeName"], let gres = Self.parseGres(fields["Gres"] ?? "") else { return nil }

        let partitions = (fields["Partitions"] ?? "").split(separator: ",").map(String.init)
            .filter { !Self.closedPartitions.contains($0) }
        guard !partitions.isEmpty else { return nil }

        self.name = name
        self.partitions = partitions
        self.flags = Self.parseState(fields["State"] ?? "")
        self.gpuTotal = gres.total
        self.gpuType = Self.groupLabel(gresTypes: gres.types, features: fields["AvailableFeatures"] ?? "")
        self.gpuAllocated = Self.gpuCount(inTRES: fields["AllocTRES"] ?? "")
        self.cpuTotal = Int(fields["CPUEfctv"] ?? fields["CPUTot"] ?? "") ?? 0
        self.cpuAllocated = Int(fields["CPUAlloc"] ?? "") ?? 0
        self.memoryTotalMB = Int(fields["RealMemory"] ?? "") ?? 0
        self.memoryAllocatedMB = Int(fields["AllocMem"] ?? "") ?? 0
        self.reason = Self.parseReason(line)
    }

    /// `gpu:a100:8(S:16-31,48-63),nvme:1` → types `[a100]`, total 8. The socket affinity
    /// has its own commas, so it has to go before splitting.
    static func parseGres(_ raw: String) -> (types: [String], total: Int)? {
        let bare = raw.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        var types: [String] = []
        var total = 0
        for part in bare.split(separator: ",") {
            let pieces = part.split(separator: ":")
            guard pieces.first == "gpu", pieces.count >= 2, let count = Int(pieces[pieces.count - 1]) else { continue }
            types.append(pieces.count >= 3 ? String(pieces[1]) : "gpu")
            total += count
        }
        return types.isEmpty ? nil : (types, total)
    }

    /// `MIXED+PLANNED`, `DOWN*+DRAIN` → flag set, without Slurm's state suffix characters.
    static func parseState(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "+").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "*~#!%$@^-")) })
    }

    /// The Gres type names the hardware, except where one type comes in memory variants
    /// told apart by a feature: `a100` plus `a100_80gb` groups as `a100_80gb`.
    static func groupLabel(gresTypes: [String], features: String) -> String {
        guard gresTypes.count == 1, let type = gresTypes.first else { return gresTypes.joined(separator: "+") }
        let variant = features.split(separator: ",").first { feature in
            feature.hasPrefix("\(type)_") && feature.hasSuffix("gb")
        }
        return variant.map(String.init) ?? type
    }

    static func gpuCount(inTRES tres: String) -> Int {
        for item in tres.split(separator: ",") where item.hasPrefix("gres/gpu=") {
            return Int(item.dropFirst("gres/gpu=".count)) ?? 0
        }
        return 0
    }

    private static func parseReason(_ line: String) -> String? {
        guard let range = line.range(of: #"Reason=.*?(?=\s+[A-Za-z_]+=|\s*$)"#, options: .regularExpression) else { return nil }
        let text = line[range].dropFirst("Reason=".count).trimmingCharacters(in: .whitespaces)
        return text.isEmpty || text == "(null)" ? nil : text
    }
}

/// All the GPUs of one kind, for one row of the availability table.
public struct GPUTypeSummary: Identifiable, Sendable {
    public let type: String
    public let partitions: [String]
    public let nodes: [HPCNode]
    public let counts: GPUCounts

    public var id: String { type }
    public var memoryTotalMB: Int { nodes.map(\.memoryTotalMB).reduce(0, +) }
    public var memoryAllocatedMB: Int { nodes.map(\.memoryAllocatedMB).reduce(0, +) }

    public static func group(_ nodes: [HPCNode]) -> [GPUTypeSummary] {
        Dictionary(grouping: nodes, by: \.gpuType).map { type, members in
            let sorted = members.sorted { a, b in
                let (ca, cb) = (a.counts, b.counts)
                if ca.ready + ca.backfill != cb.ready + cb.backfill {
                    return ca.ready + ca.backfill > cb.ready + cb.backfill
                }
                if a.isAvailable != b.isAvailable { return a.isAvailable }
                if a.gpuFree != b.gpuFree { return a.gpuFree > b.gpuFree }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return GPUTypeSummary(
                type: type,
                partitions: Array(Set(members.flatMap(\.partitions))).sorted(),
                nodes: sorted,
                counts: members.map(\.counts).reduce(GPUCounts(), +)
            )
        }
        .sorted { $0.type.localizedStandardCompare($1.type) == .orderedAscending }
    }
}
