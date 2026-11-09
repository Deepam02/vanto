import AppKit
import VoiceCommandCore

/// M4 acceptance harness: runs a scripted list of tool calls through the same policy and
/// executor the router uses, without the router or the microphone.
///
///   open dist/VoiceCommand.app --args --action-script /abs/path/golden-actions.json
///
/// Placeholders in string inputs are resolved against the live snapshot:
///   {tab:<text>}        first Chrome tab whose title or URL contains <text>
///   {tab:active}        the active tab of Chrome's front window
///   {window:<app>:<t>}  first window of <app> whose title contains <t> (or any if <t> empty)
///   {terminal:claude}   the session running claude; {terminal:shell} a plain shell;
///   {terminal:selected} the selected session
/// The report goes to ~/Library/Logs/VoiceCommand/action-script-<time>.txt.
@MainActor
final class ActionScriptRunner {
    struct Script: Decodable {
        struct Step: Decodable {
            var tool: String?
            var input: [String: JSONValue]?
            var transcript: String?
            var expect: String?          // "ok" (default) | "hold" | "reject"
            var pause_ms: Int?
            var note: String?
        }
        var steps: [Step]
    }

    private let snapshots: SnapshotBuilder
    private let executor: Executor

    init(snapshots: SnapshotBuilder, executor: Executor) {
        self.snapshots = snapshots
        self.executor = executor
    }

    func run(path: String) async -> (passed: Int, total: Int, reportURL: URL) {
        var lines: [String] = ["VoiceCommand action script: \(path)", "started \(Date())", ""]
        var passed = 0, total = 0
        let script: Script
        do {
            script = try JSONDecoder().decode(Script.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            lines.append("could not read script: \(error)")
            return (0, 1, write(lines))
        }

        for (i, step) in script.steps.enumerated() {
            if let ms = step.pause_ms, step.tool == nil {
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                continue
            }
            guard let tool = step.tool else { continue }
            total += 1
            let snap = await snapshots.refresh()
            var input: [String: Any] = [:]
            var unresolved: String?
            for (k, v) in step.input ?? [:] {
                switch v {
                case .string(let s):
                    if let r = resolve(s, snap) { input[k] = r } else { unresolved = s }
                case .bool(let b): input[k] = b
                case .number(let n): input[k] = n
                case .null: break
                }
            }
            let label = "\(i + 1). \(tool)\(step.note.map { " — \($0)" } ?? "")"
            if let unresolved {
                lines.append("FAIL \(label): placeholder \(unresolved) not found in the live snapshot")
                continue
            }
            let call: ToolCall
            do { call = try ToolCall.parse(name: tool, input: input) } catch {
                lines.append("FAIL \(label): \(error)")
                continue
            }
            let transcript = step.transcript ?? defaultTranscript(call)
            let ctx = PolicyContext(transcript: transcript, snapshot: snap, draftOpen: executor.draft != nil,
                                    draftText: executor.draft?.typedText ?? "", hasPending: false)
            let decision = ActionPolicy.evaluate(call, context: ctx)
            let want = step.expect ?? "ok"
            let t0 = Date()
            var result: String
            var ok: Bool
            switch decision {
            case .reject(let m), .skip(let m):
                result = "rejected: \(m)"; ok = want == "reject"
            case .hold(_, let prompt):
                result = "held: \(prompt)"; ok = want == "hold"
            case .run(let c, _, _):
                let out = await executor.execute(c)
                result = (out.succeeded ? "ok: " : "failed: ") + out.message
                ok = want == "ok" && out.succeeded
            }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            if ok { passed += 1 }
            lines.append("\(ok ? "PASS" : "FAIL") \(label) [\(call.summary)] → \(result) (\(ms) ms)")
            try? await Task.sleep(nanoseconds: 400_000_000)   // let the UI settle between steps
        }
        lines.append("")
        lines.append("\(passed)/\(total) steps passed")
        return (passed, total, write(lines))
    }

    private func defaultTranscript(_ call: ToolCall) -> String {
        switch call {
        case .typeText(_, _, _, let p, _): return "type \(p)"
        case .terminalRun(_, let c, _, _): return "run \(c)"
        case .submit(_, let p): return p
        case .pressKeys(let k): return "press \(k)"
        default: return call.name
        }
    }

    private func resolve(_ s: String, _ snap: DesktopSnapshot) -> String? {
        guard s.hasPrefix("{"), s.hasSuffix("}") else { return s }
        let body = String(s.dropFirst().dropLast())
        let parts = body.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "tab":
            let q = parts.dropFirst().joined(separator: ":").lowercased()
            if q == "active" { return snap.activeTab?.id }
            return snap.tabs.first { $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) }?.id
        case "window":
            let app = parts.count > 1 ? parts[1].lowercased() : ""
            let title = parts.count > 2 ? parts[2].lowercased() : ""
            return snap.windows.first { $0.app.lowercased().contains(app) && (title.isEmpty || $0.title.lowercased().contains(title)) }?.id
        case "terminal":
            switch parts.count > 1 ? parts[1] : "selected" {
            case "claude": return snap.terminals.first { $0.running == "claude" }?.id
            case "shell": return ActionPolicy.defaultShell(snap)?.id
            default: return (snap.terminals.first { $0.selected } ?? snap.terminals.first)?.id
            }
        default:
            return s
        }
    }

    private func write(_ lines: [String]) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = CommandLog.defaultURL.deletingLastPathComponent().appendingPathComponent("action-script-\(f.string(from: Date())).txt")
        try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
