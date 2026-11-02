import Foundation

/// Splits the output of a remote script into its `@@NAME` sections.
///
/// A login banner or chatty `.bashrc` can print before the first marker, so anything
/// outside a section is ignored. `@@RC n` records a section's exit status, and `@@END`
/// proves the script ran to completion rather than the connection dropping midway.
struct RemoteOutput {
    struct Section {
        var lines: [String] = []
        var exitCode = 0

        var failureMessage: String? {
            guard exitCode != 0 else { return nil }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            // How `timeout` reports stopping a command: 124 politely, 137 by force.
            if exitCode == 124 || exitCode == 137 { return text.isEmpty ? "Timed out" : "Timed out: \(text)" }
            return text.isEmpty ? "Exited with status \(exitCode)" : text
        }
    }

    private(set) var sections: [String: Section] = [:]
    private(set) var isComplete = false

    init(_ text: String) {
        var current: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line == "@@END" {
                isComplete = true
                break
            } else if line.hasPrefix("@@RC ") {
                if let current { sections[current]?.exitCode = Int(line.dropFirst(5)) ?? 1 }
            } else if line.hasPrefix("@@") {
                current = String(line.dropFirst(2))
                sections[current!] = Section()
            } else if let current {
                sections[current]?.lines.append(line)
            }
        }
    }

    func firstLine(_ name: String) -> String? {
        sections[name]?.lines.first?.trimmingCharacters(in: .whitespaces)
    }
}

/// A fetch problem, phrased for the person looking at the app.
public struct FetchFailure: Error, Sendable, Equatable {
    public let headline: String
    public let detail: String

    public init(headline: String, detail: String) {
        self.headline = headline
        self.detail = detail
    }
}
