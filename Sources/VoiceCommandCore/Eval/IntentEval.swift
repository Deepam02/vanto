import Foundation

/// The intent gate on labelled speech (docs/specs/never-lose-dictation.md §7.2): per-class
/// precision and recall for what the gate decides on the device, and the hard rule that no
/// command is ever certain dictation and no dictation is ever a certain command. Shared by
/// `swift run intent-eval` and the unit tests.
public enum IntentEval {
    public struct Case: Codable, Sendable {
        public let id: String
        public let text: String
        /// command | dictation | mixed (both in one utterance) | background (not said to Vanto)
        public let label: String
    }

    public struct File: Codable, Sendable {
        public var about: String?
        public var cases: [Case]
    }

    public static func load(_ url: URL) throws -> [Case] {
        try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases
    }

    /// What the gate did with an utterance, as one of the labels it can be certain about.
    public enum Outcome: String, CaseIterable, Sendable {
        case command, dictation, keep, router, other

        init(_ route: Decision.Route) {
            switch route {
            case .command: self = .command
            case .dictate: self = .dictation
            case .keep: self = .keep
            case .router: self = .router
            case .endRun, .recover: self = .other
            }
        }
    }

    /// The places the eval decides in. Logged speech has no recorded focus, so every case
    /// is tried in each.
    public static let contexts: [(name: String, context: IntentContext)] = {
        var media = IntentContext(focus: .textField(app: "Google Chrome"))
        media.mediaPlaying = true
        return [
            ("text field (Slack)", IntentContext(focus: .textField(app: "Slack"))),
            ("assistant prompt (Claude Code)", IntentContext(focus: .assistantPrompt(app: "Claude Code"))),
            ("nothing focused", IntentContext(focus: .none)),
            ("media playing", media),
        ]
    }()

    /// Which outcome counts as getting each label right on the device.
    static let localOutcome: [String: Outcome] = ["command": .command, "dictation": .dictation, "background": .keep]

    public struct Report: Sendable {
        /// contexts[i] → label → outcome → count
        public var counts: [[String: [Outcome: Int]]] = []
        /// Breaks of the hard rule, one line each.
        public var violations: [String] = []
        public var cases = 0
    }

    public static func run(_ cases: [Case]) -> Report {
        var r = Report()
        r.cases = cases.count
        for (name, ctx) in contexts {
            var table: [String: [Outcome: Int]] = [:]
            for c in cases {
                let d = IntentGate.decide(c.text, ctx)
                let out = Outcome(d.route)
                table[c.label, default: [:]][out, default: 0] += 1
                // 0 commands typed, 0 dictations certain commands, and background never typed.
                let broken = (c.label == "command" && out == .dictation)
                    || (c.label == "dictation" && out == .command)
                    || (c.label == "background" && out == .dictation)
                if broken { r.violations.append("\(c.id) [\(c.label) → \(out.rawValue), \(name)] \(c.text) — \(d.reason)") }
            }
            r.counts.append(table)
        }
        return r
    }

    public static func render(_ r: Report) -> String {
        func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "n/a" : String(format: "%.1f%%", Double(n) / Double(d) * 100) }
        var lines = ["\(r.cases) labelled utterances. Precision and recall are for what the gate decides on the device;",
                     "everything it isn't sure about goes to the router (not a miss, just not local).", ""]
        for (i, (name, _)) in contexts.enumerated() {
            let table = r.counts[i]
            lines.append("## \(name)")
            lines.append("| Label | n | Local outcome | Precision | Recall | To router |")
            lines.append("| --- | --- | --- | --- | --- | --- |")
            for label in ["command", "dictation", "background", "mixed"] {
                let row = table[label] ?? [:]
                let n = row.values.reduce(0, +)
                guard n > 0 else { continue }
                let routed = row[.router] ?? 0
                guard let want = localOutcome[label] else {
                    let typed = row[.dictation] ?? 0, commanded = row[.command] ?? 0
                    lines.append("| \(label) | \(n) | — (typed \(typed), certain command \(commanded)) | — | — | \(pct(routed, n)) |")
                    continue
                }
                let hit = row[want] ?? 0
                let predicted = table.values.map { $0[want] ?? 0 }.reduce(0, +)
                lines.append("| \(label) | \(n) | \(want.rawValue) | \(pct(hit, predicted)) (\(hit)/\(predicted)) | \(pct(hit, n)) (\(hit)/\(n)) | \(pct(routed, n)) |")
            }
            lines.append("")
        }
        lines.append(r.violations.isEmpty
            ? "Hard rule: 0 commands certain dictation, 0 dictations certain command, 0 background typed. ✅"
            : "Hard rule broken \(r.violations.count) times ❌\n" + r.violations.map { "- \($0)" }.joined(separator: "\n"))
        return lines.joined(separator: "\n")
    }
}
