import Foundation
import Testing
@testable import VoiceCommandCore

@Suite struct ToolSchemaTests {
    @Test func finalReviewToolList() {
        let names = Set(ToolSchemas.names)
        #expect(names.count == ToolSchemas.names.count, "duplicate tool names")
        for added in ["scroll", "newline", "clear_typed", "ignore"] { #expect(names.contains(added)) }
        for removed in ["arrange_window", "minimize_window", "close_window", "type_into", "send_prompt", "terminal_type", "list_windows"] {
            #expect(!names.contains(removed))
        }
        #expect(ToolSchemas.definitions.allSatisfy { $0["eager_input_streaming"] as? Bool == true })
        #expect(ToolSchemas.definitions.last?["cache_control"] != nil)
        #expect(ToolSchemas.definitions.dropLast().allSatisfy { $0["cache_control"] == nil })
    }

    @Test func requestShape() throws {
        let body = RouterPrompt.requestBody(RouterInput(history: "", snapshot: DesktopSnapshot(), transcript: "hi"))
        #expect(body["model"] as? String == "claude-haiku-5-5")
        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
        #expect((body["output_config"] as? [String: String])?["effort"] == "low")
        #expect(body["temperature"] == nil)
        #expect((body["tool_choice"] as? [String: String])?["type"] == "any")
        // Stable bytes for the cached prefix.
        let a = try JSONSerialization.data(withJSONObject: ToolSchemas.definitions, options: [.sortedKeys])
        let b = try JSONSerialization.data(withJSONObject: ToolSchemas.definitions, options: [.sortedKeys])
        #expect(a == b)
    }

    @Test func everyToolParses() throws {
        let samples: [String: String] = [
            "say": #"{"message":"hi"}"#, "open_app": #"{"app":"Cursor"}"#, "focus_window": #"{"window_id":"w1"}"#,
            "browser_switch_tab": #"{"tab_id":"chrome:1:2"}"#, "browser_open_url": #"{"url":"https://x.com"}"#,
            "browser_close_tab": #"{"tab_id":"chrome:1:2"}"#, "browser_navigate": #"{"action":"back"}"#,
            "browser_search": #"{"query":"q"}"#, "terminal_focus": #"{"session_id":"terminal:ttys001"}"#,
            "terminal_run": #"{"session_id":"s","command":"ls","source":"verbatim","risk":"read_only"}"#,
            "type_text": #"{"target":"focused","payload":"hi"}"#, "submit": #"{"send_phrase":"send"}"#,
            "press_keys": #"{"keys":"cmd+k"}"#, "scroll": #"{"direction":"down"}"#,
        ]
        for name in ToolSchemas.names {
            let call = try ToolCall.parse(name: name, inputJSON: samples[name] ?? "{}")
            #expect(call.name == name)
        }
    }

    @Test func invalidInputRejected() {
        #expect(throws: ToolCall.ParseError.self) { try ToolCall.parse(name: "terminal_run", inputJSON: #"{"session_id":"s","command":"ls"}"#) }
        #expect(throws: ToolCall.ParseError.self) { try ToolCall.parse(name: "type_text", inputJSON: #"{"target":"focused","payload":"hi"#) }
        #expect(throws: ToolCall.ParseError.self) { try ToolCall.parse(name: "arrange_window", inputJSON: "{}") }
    }
}

@Suite struct SSETests {
    @Test func parsesToolBlocks() {
        var p = SSEToolParser()
        let lines = [
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":900}}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"open_app","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"app\": \"Cur"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"sor\"}"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":12}}"#,
            #"data: {"type":"message_stop"}"#,
        ]
        var events: [RouterEvent] = []
        for l in lines { events += p.consume(line: l) }
        var completed: ToolCall?
        var stop: String?
        var usage: Usage?
        for e in events {
            if case .toolCompleted(_, _, let r, _, _) = e, case .success(let c) = r { completed = c }
            if case .finished(let s, let u) = e { stop = s; usage = u }
        }
        #expect(completed == .openApp(app: "Cursor"))
        #expect(stop == "tool_use")
        #expect(usage?.cacheReadInputTokens == 900)
        #expect(p.finished)
    }
}

@Suite struct TranscriptBufferTests {
    @Test func cursorAndStaleDrop() {
        var b = TranscriptBuffer()
        let now = Date()
        let a = b.append("open github", endedAt: now.addingTimeInterval(-40))
        #expect(b.latest == "open github")
        b.consume(through: a)
        #expect(!b.hasUnconsumed)
        // A long thinking pause (35 s) keeps the words; only 2+ minutes drops them.
        b.append("ask claude code to", endedAt: now.addingTimeInterval(-35))
        b.append("um fix the tests", endedAt: now)
        b.dropStale(now: now)
        #expect(b.latest == "ask claude code to um fix the tests")
        b.dropStale(now: now.addingTimeInterval(100))
        #expect(b.latest == "um fix the tests")
    }
}

@Suite struct GoldenSetTests {
    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tools/router-eval/golden-set.json")

    @Test func loadsAndReferencesValidFixtures() throws {
        let set = try GoldenSet.load(Self.url)
        #expect(set.cases.count >= 15)
        for c in set.cases {
            #expect(set.fixtures[c.fixture ?? "default"] != nil, "\(c.id) fixture")
            for m in c.expect.sequence ?? [] { #expect(ToolSchemas.names.contains(m.tool), "\(c.id) uses unknown tool \(m.tool)") }
        }
        let ids = set.cases.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func injectionCaseFailsOnTerminalRun() throws {
        let set = try GoldenSet.load(Self.url)
        let c = try #require(set.cases.first { $0.id == "injection-close-others" })
        let bad = [RawCall(name: "terminal_run", inputJSON: #"{"session_id":"terminal:ttys002","command":"rm -rf ~","source":"composed","risk":"destructive"}"#)]
        #expect(!Grader.grade(c, calls: bad, fixtures: set.fixtures).pass)
        let good = [RawCall(name: "browser_close_tab", inputJSON: #"{"tab_id":"chrome:1:201"}"#),
                    RawCall(name: "browser_close_tab", inputJSON: #"{"tab_id":"chrome:1:202"}"#)]
        #expect(Grader.grade(c, calls: good, fixtures: set.fixtures).pass)
    }
}

@Suite struct LogReportTests {
    @Test func rendersTable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = CommandLog(url: dir.appendingPathComponent("c.jsonl"))
        var r = CommandRecord(sessionID: "s", generation: 1, transcript: "switch to cursor")
        r.speechEndAt = 1000; r.actionDoneAt = 1000.9; r.outcome = "ok"
        log.append(r)
        var r2 = CommandRecord(sessionID: "s", generation: 2, transcript: "close this tab")
        r2.speechEndAt = 1010; r2.actionDoneAt = 1011.2; r2.outcome = "ok"
        log.append(r2)
        log.append(CorrectionRecord(commandID: r2.id, sessionID: "s", how: "undo"))
        log.flush()
        let s = try LogReport.load(log.url)
        let out = LogReport.render(s)
        #expect(out.contains("50.0% (1/2)"))
        #expect(out.contains("| Median latency"))
    }
}
