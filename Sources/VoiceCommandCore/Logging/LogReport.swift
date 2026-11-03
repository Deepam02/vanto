import Foundation

/// Turns the JSONL log into the PRD's success-criteria table (M7 acceptance).
public enum LogReport {
    public struct Summary {
        public var commands: [CommandRecord] = []
        public var correctedIDs: Set<String> = []
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
            case "correction": if let r = try? decoder.decode(CorrectionRecord.self, from: data) { s.correctedIDs.insert(r.commandID) }
            case "session": s.sessions += 1
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

    /// Commands that did something (not wait_for_more / ignore / router errors).
    static func acted(_ s: Summary) -> [CommandRecord] {
        s.commands.filter { ["ok", "failed", "pending", "rejected"].contains($0.outcome) }
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
        rows.append("")
        rows.append("Also: \(s.commands.count) routed utterances, \(acted.count) acted on, \(s.sessions) sessions. Router time to first tool call p50 \(ms(percentile(ttft, 0.5))), p90 \(ms(percentile(ttft, 0.9))). Latency p90 \(ms(percentile(latencies, 0.9))).")
        return rows.joined(separator: "\n")
    }
}
