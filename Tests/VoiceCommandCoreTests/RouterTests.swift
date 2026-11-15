import Foundation
import Testing
@testable import VoiceCommandCore

@Suite struct ToolSchemaTests {
    @Test func finalReviewToolList() {
        let names = Set(ToolSchemas.names)
        #expect(names.count == ToolSchemas.names.count, "duplicate tool names")
        for added in ["scroll", "newline", "clear_typed", "keep", "dictate"] { #expect(names.contains(added)) }
        #expect(!names.contains("ignore"), "ignore became keep: words are never dropped")
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
            "press_keys": #"{"keys":"cmd+k"}"#, "scroll": #"{"direction":"left"}"#,
            "menu_command": #"{"item":"Zoom Out","menu":"View"}"#, "click_element": #"{"name":"Conversations"}"#,
            "rewrite_draft": #"{"text":"Hello."}"#, "start_dictation": #"{"target":"focused"}"#,
            "system_volume": #"{"action":"set","level":50}"#,
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

    /// keep takes only the router's three reasons; dictate has no payload.
    @Test func keepAndDictate() throws {
        #expect(try ToolCall.parse(name: "keep", inputJSON: #"{"reason":"noise"}"#) == .keep(reason: .noise))
        #expect(try ToolCall.parse(name: "keep", inputJSON: #"{"reason":"not_for_me"}"#) == .keep(reason: .notForMe))
        #expect(try ToolCall.parse(name: "keep", inputJSON: "{}") == .keep(reason: .unclear))
        #expect(throws: ToolCall.ParseError.self) { try ToolCall.parse(name: "keep", inputJSON: #"{"reason":"stale"}"#) }
        #expect(throws: ToolCall.ParseError.self) { try ToolCall.parse(name: "ignore", inputJSON: "{}") }
        #expect(try ToolCall.parse(name: "dictate", inputJSON: "{}") == .dictate(target: nil, app: nil, sessionID: nil))
        #expect(try ToolCall.parse(name: "dictate", inputJSON: #"{"target":"terminal","session_id":"terminal:ttys001","payload":"x"}"#)
                == .dictate(target: .terminal, app: nil, sessionID: "terminal:ttys001"))
        #expect(throws: ToolCall.ParseError.self) { try ToolCall.parse(name: "dictate", inputJSON: #"{"target":"draft"}"#) }
        #expect(ToolCall.keep(reason: .noise).summary == "keep(noise)")
        #expect(ToolCall.dictate(target: nil, app: "Slack", sessionID: nil).summary == "dictate(app: Slack)")
    }

    /// The router sees focus, the run, media and what a question was about.
    @Test func sessionStateForDictation() {
        var h = SessionHistory()
        h.add(.init(transcript: "Enter into dictation Code.", actions: ["say"], outcome: "Which app should I dictate into?"))
        let msg = RouterPrompt.userMessage(RouterInput(
            history: h.render(), snapshot: DesktopSnapshot(), transcript: "Claude Code",
            lastQuestion: h.lastQuestion, questionAbout: h.lastQuestionAbout,
            focus: .assistantPrompt(app: "Claude Code"), dictationRun: "Claude Code", mediaPlaying: true))
        #expect(msg.contains("focus: assistant prompt (Claude Code)"))
        #expect(msg.contains("dictation_run: typing into Claude Code (not sent)"))
        #expect(msg.contains("media_playing: yes"))
        #expect(msg.contains("you_just_asked: \"Which app should I dictate into?\""))
        #expect(msg.contains("asked_about: \"Enter into dictation Code.\""))

        let plain = RouterPrompt.userMessage(RouterInput(history: "", snapshot: DesktopSnapshot(), transcript: "hi"))
        #expect(plain.contains("dictation_run: none"))
        #expect(!plain.contains("media_playing") && !plain.contains("asked_about") && !plain.contains("focus:"))

        // An answer that wasn't a question has nothing to carry.
        h.add(.init(transcript: "open slack", actions: ["open_app(Slack) → ok"], outcome: "Opened Slack"))
        #expect(h.lastQuestionAbout == nil)
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
    @Test func disposeAndKeepStale() {
        var b = TranscriptBuffer()
        let now = Date()
        let a = b.append("open github", endedAt: now.addingTimeInterval(-40))
        #expect(b.latest == "open github")
        b.dispose(through: a, as: .acted)
        #expect(!b.hasPending)
        // A long thinking pause (35 s) keeps the words waiting; only 2+ minutes keeps them aside.
        b.append("ask claude code to", endedAt: now.addingTimeInterval(-35))
        b.append("um fix the tests", endedAt: now)
        b.keepStale(now: now)
        #expect(b.latest == "ask claude code to um fix the tests")
        b.keepStale(now: now.addingTimeInterval(100))
        #expect(b.latest == "um fix the tests")
        let out = b.takeDisposed()
        #expect(out.map(\.disposition) == [.acted, .kept(.stale)])
        #expect(out.last?.text == "ask claude code to")
        #expect(b.takeDisposed().isEmpty)
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
