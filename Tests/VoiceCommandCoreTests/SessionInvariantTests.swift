import Foundation
import Testing
@testable import VoiceCommandCore

/// Spec §7.1 at session level: random speech, gate decisions, router replies (including errors
/// and timeouts), dictation runs, focus changes and session ends, driven through the same
/// pieces SessionController uses (TranscriptBuffer, ReplyOutcome, DispositionLedger). Every
/// segment heard gets exactly one disposition, and the ledger agrees.
@Suite struct SessionInvariantTests {
    /// What SessionController does with a buffer, reduced to the moves that touch dispositions.
    struct Session {
        var buffer = TranscriptBuffer()
        var ledger = DispositionLedger()
        /// Segments a dictation run holds (claimed), waiting to be typed.
        var run: [Int] = []
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        /// Every disposition collected, per segment (what the speech history saw).
        var written: [Int: Int] = [:]

        mutating func hear(_ text: String) {
            buffer.append(text, endedAt: now)
            ledger.note(buffer)
        }

        /// recordDisposed(): collect, note in the ledger, write.
        mutating func record() {
            let done = buffer.takeDisposed()
            ledger.record(done)
            for d in done { for s in d.segments { written[s.id, default: 0] += 1 } }
        }

        /// A router reply covering everything waiting. nil = newer speech cancelled it: the words
        /// stay and are routed again with the new ones.
        mutating func reply(_ r: ReplyOutcome?) {
            let ids = buffer.latestSegmentIDs
            guard let r, let last = ids.last else { return }
            if r.dictated {
                // The engine claims the words and disposes them itself.
                buffer.claim(ids)
                run += ids
            }
            if let d = r.disposition { buffer.dispose(through: last, as: d) }
            record()
        }

        /// The engine typed (or failed to type) what it holds.
        mutating func runTyped(ok: Bool, reason: KeptReason = .nowhereToType) {
            buffer.dispose(run, as: ok ? .typed : .kept(reason))
            run = []
            record()
        }

        mutating func end() {
            buffer.reset(at: now)
            run = []
            record()
        }
    }

    static func randomReply(_ rng: inout SeededRandom) -> ReplyOutcome? {
        var r = ReplyOutcome()
        switch rng.next(10) {
        case 0: return nil                                   // cancelled by newer speech
        case 9: r.errored = true                             // router error or timeout: kept(error)
        case 1: r.waited = true                              // wait_for_more
        case 2: r.acted = true; r.succeeded = true; r.outcomeLines = 1
        case 3: r.acted = true; r.failed = true; r.outcomeLines = 1
        case 4: r.kept = [.noise, .notForMe, .unclear][rng.next(3)]
        case 5: r.acted = true; r.succeeded = true; r.asked = true; r.outcomeLines = 1
        case 6: r.held = true; r.outcomeLines = 1
        case 7: r.dictated = true; r.outcomeLines = 1
        default: r.ended = true
        }
        return r
    }

    @Test func everySegmentHeardGetsExactlyOneDisposition() {
        var rng = SeededRandom(seed: 7)
        for _ in 0..<300 {
            var s = Session()
            var heard = Set<Int>()
            for _ in 0..<rng.next(40) {
                s.now = s.now.addingTimeInterval(Double(rng.next(60)))
                switch rng.next(10) {
                case 0, 1, 2:
                    let text = rng.next(8) == 0 ? " " : "words \(rng.next(1000))"
                    let before = Set(s.buffer.latestSegmentIDs)
                    s.hear(text)
                    heard.formUnion(Set(s.buffer.latestSegmentIDs).subtracting(before))
                case 3, 4:
                    s.reply(Self.randomReply(&rng))
                case 5:
                    // Local dictation: the gate typed it, the run holds it until it's typed.
                    let ids = s.buffer.latestSegmentIDs
                    s.buffer.claim(ids)
                    s.run += ids
                case 6:
                    s.runTyped(ok: rng.next(3) != 0)
                case 7:
                    // Focus moved off the run's place: its waiting words are kept (moved away),
                    // and the next words are kept too when there's nothing to type into.
                    s.runTyped(ok: false, reason: .movedAway)
                    if rng.next(2) == 0 { s.buffer.disposeAll(as: .kept(.movedAway)); s.record() }
                case 8:
                    // Recovery phrase or mute: disposed as acted; "scratch that" discards a chunk.
                    if rng.next(2) == 0 { s.buffer.disposeAll(as: .acted) } else if let last = s.run.popLast() { s.buffer.dispose([last], as: .discarded) }
                    s.record()
                default:
                    // The once-a-second sweep.
                    if s.buffer.keepStale(now: s.now) { s.record() }
                }
            }
            if rng.next(4) == 0 {
                // A session can end mid-reply; leftovers are kept as session_ended.
                s.reply(Self.randomReply(&rng))
            }
            s.end()
            #expect(!s.buffer.hasPending)
            #expect(Set(s.written.keys) == heard)
            #expect(s.written.values.allSatisfy { $0 == 1 })
            #expect(s.ledger.undisposed.isEmpty)
            #expect(s.ledger.doubled.isEmpty)
        }
    }

    /// The ledger catches a disposition that never reached the history.
    @Test func ledgerFindsWordsNeverWritten() {
        var s = Session()
        s.hear("hello there")
        s.hear("and more")
        let first = s.buffer.latestSegmentIDs[0]
        s.buffer.dispose([first], as: .acted)
        _ = s.buffer.takeDisposed()   // collected, but not recorded: lost to the history
        s.end()
        #expect(s.ledger.undisposed == [first])
    }

    @Test func replyDispositions() {
        var r = ReplyOutcome()
        r.waited = true
        #expect(r.disposition == nil)
        r = ReplyOutcome()
        #expect(r.disposition == .acted)   // a reply with nothing in it still moves on
        r.acted = true; r.failed = true; r.outcomeLines = 1
        #expect(r.disposition == .kept(.failed))
        r.succeeded = true
        #expect(r.disposition == .acted)
        r = ReplyOutcome(); r.acted = true; r.succeeded = true; r.asked = true; r.outcomeLines = 1
        #expect(r.disposition == .kept(.unclear))
        r.outcomeLines = 2
        #expect(r.disposition == .acted)
        r = ReplyOutcome(); r.kept = .noise
        #expect(r.disposition == .kept(.noise))
        r = ReplyOutcome(); r.waited = true; r.held = true
        #expect(r.disposition == .acted)
        r = ReplyOutcome(); r.errored = true
        #expect(r.disposition == .kept(.error))
    }

    /// Review, 14 Nov: a long prompt timed out twice, then "switch to Chrome" was routed with it
    /// and the prompt went to the history as acted. Now the failed route keeps it at once.
    @Test func routerErrorKeepsTheWordsBeforeTheNextCommand() {
        var s = Session()
        s.hear("so the plan is to move the launch to next week because the flow isn't ready")
        let prompt = s.buffer.latestSegmentIDs
        var failed = ReplyOutcome(); failed.errored = true
        s.reply(failed)
        s.hear("switch to Chrome")
        #expect(s.buffer.latest == "switch to Chrome")
        var ran = ReplyOutcome(); ran.acted = true; ran.succeeded = true; ran.outcomeLines = 1
        s.reply(ran)
        s.end()
        #expect(prompt.allSatisfy { s.written[$0] == 1 })
        #expect(s.ledger.doubled.isEmpty && s.ledger.undisposed.isEmpty)
    }
}

/// Spec §7.3, loss path 3: row 75's prompt for Claude desktop failed with "No text field is
/// focused" and the words were consumed. Now they're kept, and "type it" brings them back.
@Suite struct KeptAndTypeItReplayTests {
    @Test func failedTypingIsKeptAndTypeItFindsIt() {
        let said = "So, based on these screens, I want you to like. plan, like work with me and brainstorm like when we should introduce the sidebar"
        // Nothing focused in Claude desktop: not certain either way, so the router decides.
        #expect(IntentGate.decide(said, IntentContext(focus: .none)).route == .router)

        // The router said dictate; the engine had nowhere to type, so the words are kept.
        let url = SpeechHistoryTests.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let history = SpeechHistory(url: url)
        var b = TranscriptBuffer()
        let id = b.append(said)
        b.claim([id])
        var reply = ReplyOutcome()
        reply.dictated = true; reply.outcomeLines = 1
        if let d = reply.disposition { b.dispose(through: id, as: d) }
        #expect(b.takeDisposed().isEmpty)   // claimed: the engine disposes it
        b.dispose([id], as: .kept(.nowhereToType))
        history.append(b.takeDisposed(), sessionID: "s75", app: "Claude")
        #expect(history.lastKept?.text == said)
        #expect(history.lastKept?.disposition == .kept(.nowhereToType))

        // They click the text box and say "type it".
        let ctx = IntentContext(focus: .textField(app: "Claude"), hasKept: true)
        #expect(IntentGate.decide("type it", ctx).route == .recover(.typeKept(about: nil)))
        #expect(IntentGate.decide("Type the one about the sidebar.", ctx).route == .recover(.typeKept(about: "the sidebar")))
        #expect(history.kept(matching: "the sidebar")?.text == said)
    }
}

/// `swift run intent-eval` and the tests share IntentEval: its hard rule holds on the file.
@Suite struct IntentEvalTests {
    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tools/intent-eval/labelled-utterances.json")

    @Test func hardRuleHolds() throws {
        let cases = try IntentEval.load(Self.url)
        #expect(cases.filter { $0.id.hasPrefix("persona-") }.count >= 60)
        let report = IntentEval.run(cases)
        #expect(report.violations.isEmpty, "\(report.violations)")
        #expect(IntentEval.render(report).contains("✅"))
    }
}

@Suite struct LogReportNeverLoseTests {
    @Test func oldAndNewLinesParseAndCount() throws {
        let lines = [
            // An old line from before the feature: no intent, disposition or segments.
            #"{"kind":"command","id":"old","sessionID":"s0","generation":1,"transcript":"open Slack","tools":["switch_app"],"decisions":[],"results":[],"outcome":"ok","irreversible":false,"mismatchNotes":[],"retried":false}"#,
            #"{"kind":"session","sessionID":"s0","startedAt":1,"endedAt":2,"endReason":"hotkey"}"#,
            // New: a typed dictation that was a command, a kept paragraph typed back, a lost segment.
            #"{"kind":"command","id":"d1","sessionID":"s1","generation":1,"transcript":"switch to chrome and","tools":["dictation"],"decisions":[],"results":[],"outcome":"ok","irreversible":false,"mismatchNotes":[],"retried":false,"disposition":"typed","segments":[0],"intent":"local: certain dictation","focusKind":"text field (Slack)","mediaPlaying":false}"#,
            #"{"kind":"disposition","sessionID":"s1","segments":[0],"disposition":"typed","at":3}"#,
            #"{"kind":"correction","commandID":"d1","sessionID":"s1","how":"was_command","at":4}"#,
            #"{"kind":"command","id":"c1","sessionID":"s1","generation":2,"transcript":"switch to chrome","tools":["switch_app"],"decisions":[],"results":[],"outcome":"ok","irreversible":false,"mismatchNotes":[],"retried":false,"segments":[1]}"#,
            #"{"kind":"disposition","sessionID":"s1","segments":[1],"disposition":"acted","at":5}"#,
            #"{"kind":"disposition","sessionID":"s1","segments":[2],"disposition":"kept:nowhere_to_type","at":6}"#,
            #"{"kind":"disposition","sessionID":"s1","segments":[3],"disposition":"kept:noise","at":6}"#,
            #"{"kind":"command","id":"r1","sessionID":"s1","generation":3,"transcript":"type it","tools":["recovery"],"decisions":["type kept → Typed into Notes"],"results":[],"outcome":"ok","irreversible":false,"mismatchNotes":[],"retried":false,"segments":[4]}"#,
            #"{"kind":"disposition","sessionID":"s1","segments":[4],"disposition":"acted","at":7}"#,
            #"{"kind":"command","id":"x1","sessionID":"s1","generation":4,"transcript":"lost words","tools":[],"decisions":[],"results":[],"outcome":"error","irreversible":false,"mismatchNotes":[],"retried":false,"segments":[5]}"#,
            #"{"kind":"session","sessionID":"s1","startedAt":1,"endedAt":9,"endReason":"hotkey","wordsLost":0}"#,
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let s = try LogReport.load(url)
        #expect(s.commands.count == 5)
        #expect(s.sessions == 2)
        let n = LogReport.neverLose(s)
        #expect(n.tracked == 4)
        #expect(n.wordsLost == 1)          // segment 5 was routed and never disposed
        #expect(n.dictations == 1)
        #expect(n.wasCommand == 1)
        #expect(n.kept == 1)               // background noise doesn't count
        #expect(n.recovered == 1)
        #expect(LogReport.render(s).contains("Words lost"))
    }
}
