import Foundation

/// Turns the JSONL log into the PRD's success-criteria table (M7 acceptance).
public enum LogReport {
    public struct Summary {
        public var commands: [CommandRecord] = []
        public var correctedIDs: Set<String> = []
        public var corrections: [CorrectionRecord] = []
        public var dispositions: [DispositionRecord] = []
        public var sessionRecords: [SessionRecord] = []
        public var sessions = 0
    }

    public static func load(_ url: URL) throws -> Summary {
        let text = try String(contentsOf: url, encoding: .utf8)
        var s = Summary()
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n") where !line.isEmpty {
            let data = Data(line.utf8)
            guard let kind = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["kind"] as? String else { continue }
            switch kind {
            case "command": if let r = try? decoder.decode(CommandRecord.self, from: data) { s.commands.append(r) }
            case "correction":
                if let r = try? decoder.decode(CorrectionRecord.self, from: data) { s.correctedIDs.insert(r.commandID); s.corrections.append(r) }
            case "disposition": if let r = try? decoder.decode(DispositionRecord.self, from: data) { s.dispositions.append(r) }
            case "session":
                s.sessions += 1
                if let r = try? decoder.decode(SessionRecord.self, from: data) { s.sessionRecords.append(r) }
            default: break
            }
        }
        return s
    }

    static func percentile(_ values: [Int], _ p: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let idx = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[idx]
    }

    /// Commands that did something (not wait_for_more / keep / router errors).
    static func acted(_ s: Summary) -> [CommandRecord] {
        s.commands.filter { ["ok", "failed", "pending", "rejected"].contains($0.outcome) }
    }

    /// The never-lose-dictation measures (spec §5.8). Only logs written since dispositions were
    /// logged (13 Nov) count; older lines have no segments and are left out.
    public struct NeverLose: Equatable {
        /// Segments without a disposition: routed but never disposed, plus what sessions reported.
        public var wordsLost = 0
        /// Utterances that logged their segments (the denominator for words lost).
        public var tracked = 0
        /// Utterances typed as dictation, and how many were then "that was a command".
        public var dictations = 0
        public var wasCommand = 0
        /// Commands acted on, and how many were then "type that instead".
        public var commands = 0
        public var typeInstead = 0
        /// Kept groups (not background noise), and how many were later typed or copied back.
        public var kept = 0
        public var recovered = 0
    }

    public static func neverLose(_ s: Summary) -> NeverLose {
        var n = NeverLose()
        var disposed = Set<String>()
        for d in s.dispositions { for id in d.segments { disposed.insert("\(d.sessionID)#\(id)") } }
        let tracked = s.commands.filter { $0.segments != nil }
        n.tracked = tracked.count
        var routed = Set<String>()
        for r in tracked { for id in r.segments ?? [] { routed.insert("\(r.sessionID)#\(id)") } }
        n.wordsLost = routed.subtracting(disposed).count + s.sessionRecords.compactMap(\.wordsLost).reduce(0, +)

        let hows = s.corrections.map(\.how)
        n.dictations = s.commands.filter { $0.disposition == "typed" || $0.tools.contains("dictation") || $0.tools.contains("dictate") }.count
        n.wasCommand = hows.filter { $0 == "was_command" }.count
        n.commands = acted(s).filter { !$0.tools.contains("dictation") && !$0.tools.contains("recovery") }.count
        n.typeInstead = hows.filter { $0 == "type_instead" }.count
        n.kept = s.dispositions.filter { $0.disposition.hasPrefix("kept:") && $0.disposition != "kept:noise" }.count
        n.recovered = s.commands.filter {
            $0.tools == ["recovery"] && ($0.decisions.first.map { $0.hasPrefix("type kept") || $0.hasPrefix("copy kept") } ?? false)
        }.count
        return n
    }

    public static func render(_ s: Summary, now: Date = Date()) -> String {
        let acted = acted(s)
        let simple = acted.filter { $0.outcome == "ok" && !$0.irreversible }
        let latencies = simple.compactMap(\.latencyMs)
        let ttft = s.commands.compactMap(\.timeToFirstToolMs)

        let firstTry = acted.filter { $0.outcome == "ok" && !s.correctedIDs.contains($0.id) }.count
        let correctPct = acted.isEmpty ? nil : Double(firstTry) / Double(acted.count) * 100
        let wrongIrreversible = acted.filter { $0.irreversible && s.correctedIDs.contains($0.id) }.count

        // Commands per working day in week two (days 8–14 after the first logged command).
        var perDayWeek2: Double?
        if let first = acted.compactMap(\.speechEndAt).min() {
            let start = first + 7 * 86400, end = first + 14 * 86400
            let cal = Calendar.current
            var days: [Date: Int] = [:]
            for r in acted { if let t = r.speechEndAt, t >= start, t < end {
                days[cal.startOfDay(for: Date(timeIntervalSince1970: t)), default: 0] += 1
            } }
            if !days.isEmpty { perDayWeek2 = Double(days.values.reduce(0, +)) / Double(days.count) }
        }

        func ms(_ v: Int?) -> String { v.map { String(format: "%.2f s", Double($0) / 1000) } ?? "n/a" }
        func pass(_ ok: Bool?) -> String { ok.map { $0 ? "✅" : "❌" } ?? "—" }

        let p50 = percentile(latencies, 0.5)
        var rows: [String] = [
            "| Measure | Target | Actual | |",
            "| --- | --- | --- | --- |",
            "| Median latency, end of speech to action done (MVP) | ≤ 1.1 s | \(ms(p50)) | \(pass(p50.map { $0 <= 1100 })) |",
            "| Median latency, end of speech to action done (post-speculation goal) | ≤ 800 ms | \(ms(p50)) | \(pass(p50.map { $0 <= 800 })) |",
            "| Correct action on the first try | ≥ 90% | \(correctPct.map { String(format: "%.1f%%", $0) } ?? "n/a") (\(firstTry)/\(acted.count)) | \(pass(correctPct.map { $0 >= 90 })) |",
            "| Wrong irreversible action (undone or corrected send / command) | 0 | \(wrongIrreversible) | \(pass(acted.isEmpty ? nil : wrongIrreversible == 0)) |",
            "| Voice commands per working day, week two | ≥ 20 | \(perDayWeek2.map { String(format: "%.1f", $0) } ?? "n/a (no week-two data yet)") | \(pass(perDayWeek2.map { $0 >= 20 })) |",
        ]
        let n = neverLose(s)
        func rate(_ a: Int, _ b: Int) -> String { b == 0 ? "n/a" : String(format: "%.1f%% (%d/%d)", Double(a) / Double(b) * 100, a, b) }
        let tracked = n.tracked > 0
        rows += [
            "| Words lost (segments without a disposition) | 0 | \(tracked ? "\(n.wordsLost)" : "n/a (no segments logged yet)") | \(pass(tracked ? n.wordsLost == 0 : nil)) |",
            "| Typed, then “that was a command” (false dictation) | ≤ 1 per 50 commands | \(rate(n.wasCommand, n.dictations)); \(n.wasCommand) per \(n.commands) commands | \(pass(n.commands == 0 || n.dictations == 0 ? nil : n.wasCommand * 50 <= n.commands)) |",
            "| Acted on, then “type that instead” (false command) | — | \(rate(n.typeInstead, n.commands)) | — |",
            "| Kept items later typed or copied back | — | \(rate(n.recovered, n.kept)) | — |",
        ]
        rows.append("")
        rows.append("Also: \(s.commands.count) routed utterances, \(acted.count) acted on, \(s.sessions) sessions. Router time to first tool call p50 \(ms(percentile(ttft, 0.5))), p90 \(ms(percentile(ttft, 0.9))). Latency p90 \(ms(percentile(latencies, 0.9))).")
        return rows.joined(separator: "\n")
    }
}
