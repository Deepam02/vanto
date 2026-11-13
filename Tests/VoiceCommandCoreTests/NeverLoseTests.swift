import Foundation
import Testing
@testable import VoiceCommandCore

/// Never lose dictation (docs/specs/never-lose-dictation.md): the buffer's dispositions, the
/// speech history, typing mode, and live typing with recovery phrases.
@Suite struct DispositionInvariantTests {
    /// I1: random appends, router replies (acted, ignored, failed, waiting), stale sweeps and
    /// session ends. Every segment with words leaves the buffer exactly once, with a disposition.
    @Test func everySegmentGetsExactlyOneDisposition() {
        var rng = SeededRandom(seed: 42)
        for _ in 0..<200 {
            var b = TranscriptBuffer()
            var appended = Set<Int>()
            var now = Date(timeIntervalSince1970: 1_800_000_000)
            var seen: [Int: Int] = [:]
            func collect() { for d in b.takeDisposed() { for s in d.segments { seen[s.id, default: 0] += 1 } } }
            for _ in 0..<rng.next(30) {
                now = now.addingTimeInterval(Double(rng.next(90)))
                switch rng.next(7) {
                case 0, 1, 2:
                    let text = rng.next(6) == 0 ? "  " : "words \(rng.next(1000))"
                    let id = b.append(text, endedAt: now)
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty { appended.insert(id) }
                case 3:
                    let all: [Disposition] = [.acted, .typed, .kept(.notForMe), .kept(.failed), .discarded]
                    if let last = b.latestSegmentIDs.last { b.dispose(through: last, as: all[rng.next(all.count)]) }
                case 4:
                    break   // wait_for_more, or a router error: the words stay
                case 5:
                    b.keepStale(now: now)
                default:
                    // Disposing ids twice, or ids that never had words, changes nothing.
                    b.dispose(Array(seen.keys) + [999_999], as: .acted)
                }
                collect()
            }
            b.reset(at: now)
            collect()
            #expect(!b.hasPending)
            #expect(Set(seen.keys) == appended)
            #expect(seen.values.allSatisfy { $0 == 1 })
        }
    }

    @Test func sessionEndKeepsWhatWasWaiting() {
        var b = TranscriptBuffer()
        b.append("I think we need to")
        b.append("improve the screens", raw: "improve the scenes")
        b.reset()
        let out = b.takeDisposed()
        #expect(out.count == 1)
        #expect(out[0].disposition == .kept(.sessionEnded))
        #expect(out[0].text == "I think we need to improve the screens")
        #expect(out[0].raw == "I think we need to improve the scenes")
    }

    @Test func dispositionLabelsRoundTrip() throws {
        let all: [Disposition] = [.acted, .typed, .discarded] + KeptReason.allCases.map { .kept($0) }
        for d in all {
            #expect(Disposition(label: d.label) == d)
            let data = try JSONEncoder().encode([d])
            #expect(try JSONDecoder().decode([Disposition].self, from: data) == [d])
        }
        #expect(Disposition.kept(.stale).label == "kept:stale")
        #expect(try JSONDecoder().decode([Disposition].self, from: Data(#"["kept:someday"]"#.utf8)) == [.kept(.unclear)])
    }
}

@Suite struct SpeechHistoryTests {
    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-history-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("history.jsonl")
    }

    @Test func appendQueryAndClear() {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let h = SpeechHistory(url: url)
        #expect(h.lastKept == nil)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        h.append([
            .init(at: t0, text: "open Slack", disposition: .acted, sessionID: "s1"),
            .init(at: t0 + 1, text: "the deck is ready, I'll walk you through it tomorrow", disposition: .kept(.nowhereToType), sessionID: "s1"),
            .init(at: t0 + 2, text: "we need to improve the onboarding", disposition: .typed, sessionID: "s1", app: "Claude"),
            .init(at: t0 + 3, text: "never mind that last part", disposition: .discarded, sessionID: "s1"),
            .init(at: t0 + 4, text: "   ", disposition: .kept(.noise)),
        ])
        #expect(h.recent().map(\.text) == ["never mind that last part", "we need to improve the onboarding",
                                           "the deck is ready, I'll walk you through it tomorrow", "open Slack"])
        #expect(h.kept().map(\.text) == ["never mind that last part", "the deck is ready, I'll walk you through it tomorrow"])
        #expect(h.lastKept?.disposition == .discarded)
        #expect(h.kept(matching: "the one about the deck")?.text == "the deck is ready, I'll walk you through it tomorrow")
        #expect(h.kept(matching: "the one about penguins") == nil)

        // A fresh store reads the same file back.
        let again = SpeechHistory(url: url)
        #expect(again.recent().count == 4)
        #expect(again.kept().first?.text == "never mind that last part")
        #expect(again.all().map(\.disposition) == [.acted, .kept(.nowhereToType), .typed, .discarded])

        h.clear()
        #expect(h.recent().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(SpeechHistory(url: url).kept().isEmpty)
    }

    @Test func fromTheBuffer() {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let h = SpeechHistory(url: url)
        var b = TranscriptBuffer()
        let a = b.append("switch to Chrome")
        b.dispose([a], as: .acted)
        b.append("so basically the thing I need to convey")
        b.reset()
        h.append(b.takeDisposed(), sessionID: "s2", app: "Ghostty")
        #expect(h.recent().map(\.disposition) == [.kept(.sessionEnded), .acted])
        #expect(h.recent().allSatisfy { $0.sessionID == "s2" && $0.app == "Ghostty" })
    }

    /// No expiry and no cap: a big file is read from its tail, and the Kept list still
    /// finds kept words that are older than the in-memory window.
    @Test func largeFileReadsTheTail() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        var data = Data()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        for i in 0..<20_000 {
            let kept = i % 400 == 0
            let e = SpeechHistory.Entry(id: "e\(i)", at: t0 + Double(i), text: kept ? "kept number \(i)" : "command number \(i)",
                                        disposition: kept ? .kept(.notForMe) : .acted)
            data.append(try enc.encode(e)); data.append(0x0A)
        }
        try data.write(to: url)
        let start = Date()
        let h = SpeechHistory(url: url, recentLimit: 200, keptLimit: 10)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(h.recent(limit: 1).first?.id == "e19999")
        #expect(h.kept().map(\.id) == stride(from: 19_600, through: 16_000, by: -400).map { "e\($0)" })
        // Older than anything in memory: found by reading the whole file.
        #expect(h.kept(matching: "kept number 400")?.id == "e400")
    }
}

@Suite struct TypingModeTests {
    @Test func policy() {
        // Long prompts and long-form writing, decided on the device: typed as you go.
        #expect(TypingMode.choose(surface: .assistant, source: .local, mediaPlaying: false) == .live)
        #expect(TypingMode.choose(surface: .longForm, source: .local, mediaPlaying: false) == .live)
        // Message boxes: one clean paste once speech pauses.
        #expect(TypingMode.choose(surface: .message, source: .local, mediaPlaying: false) == .onPause)
        #expect(TypingMode.choose(surface: .other, source: .local, mediaPlaying: false) == .onPause)
        // Not certain, or something playing: paste on a pause, even into a prompt.
        #expect(TypingMode.choose(surface: .assistant, source: .router, mediaPlaying: false) == .onPause)
        #expect(TypingMode.choose(surface: .longForm, source: .local, mediaPlaying: true) == .onPause)
        // Hold Fn keeps type-on-release.
        #expect(TypingMode.choose(surface: .assistant, source: .holdFn, mediaPlaying: false) == .onRelease)
        #expect(TypingMode.choose(surface: .message, source: .holdFn, mediaPlaying: true) == .onRelease)
    }

    @Test func surfaces() {
        #expect(TypingMode.surface(app: "Ghostty", bundleID: "com.mitchellh.ghostty", terminalProgram: "claude") == .assistant)
        #expect(TypingMode.surface(app: "Terminal", terminalProgram: "codex") == .assistant)
        #expect(TypingMode.surface(app: "Terminal", terminalProgram: nil) == .other)
        #expect(TypingMode.surface(app: "Claude", bundleID: "com.anthropic.claudefordesktop") == .assistant)
        #expect(TypingMode.surface(app: "Cursor") == .assistant)
        #expect(TypingMode.surface(app: "ChatGPT") == .assistant)
        #expect(TypingMode.surface(app: "Notes", bundleID: "com.apple.Notes") == .longForm)
        #expect(TypingMode.surface(app: "Slack", bundleID: "com.tinyspeck.slackmacgap") == .message)
        #expect(TypingMode.surface(app: "Messages", bundleID: "com.apple.MobileSMS") == .message)
        #expect(TypingMode.surface(app: "WhatsApp") == .message)
        #expect(TypingMode.surface(app: "Mail") == .message)
        #expect(TypingMode.surface(app: "Discord") == .message)
        #expect(TypingMode.surface(app: "Microsoft Teams", bundleID: "com.microsoft.teams2") == .message)
        // Web apps by address.
        #expect(TypingMode.surface(app: "Google Chrome", url: "https://mail.google.com/mail/u/0/#inbox") == .message)
        #expect(TypingMode.surface(app: "Google Chrome", url: "https://x.com/home") == .message)
        #expect(TypingMode.surface(app: "Google Chrome", url: "https://www.linkedin.com/feed/") == .message)
        #expect(TypingMode.surface(app: "Google Chrome", url: "https://docs.google.com/document/d/1") == .longForm)
        #expect(TypingMode.surface(app: "Google Chrome", url: "https://www.notion.so/team/page") == .longForm)
        #expect(TypingMode.surface(app: "Google Chrome", url: "https://claude.ai/new") == .assistant)
        #expect(TypingMode.surface(app: "Google Chrome", url: "https://chatgpt.com/") == .assistant)
        #expect(TypingMode.surface(app: "Google Chrome", url: "https://www.netflix.com/browse") == .other)
        #expect(TypingMode.surface(app: "Finder") == .other)
    }

    @Test func fromTheGate() {
        let field = IntentContext(focus: .assistantPrompt(app: "Claude Code"))
        let local = IntentGate.decide("I think we need to plan out a few features and do some research on what people are missing", field)
        #expect(local.source == .local)
        #expect(IntentGate.decide("That's how we will grow it", field).source == .router)
        #expect(IntentGate.decide("anything at all", IntentContext(holdFn: true)).source == .holdFn)
    }
}

@Suite struct LiveTypingTests {
    /// Typing each `mend` in turn gives what `clean` gives for the whole run.
    @Test func mendMatchesClean() {
        let runs: [[String]] = [
            ["Can you draft a prompt for this? Like the prompt is I think we need to improve the redesigning of the screens.",
             "Um let me think.", "Like for example, we need to add some sort of Linear to it I guess.", "Uh and like.", "Cleaner onboarding."],
            ["We need to.", "Ship it today."],
            ["Done.", "Next thing."],
            ["Tell them that.", "I said yes."],
            ["I think um.", "We should go."],
            ["Um.", "Hello there."],
        ]
        for segments in runs {
            var typed = ""
            for s in segments {
                let m = Dictation.mend(typed: typed, next: s)
                typed.removeLast(m.backspaces)
                typed += m.text
            }
            #expect(typed == Dictation.clean(segments), "\(segments)")
        }
    }

    @Test func mendSteps() {
        #expect(Dictation.mend(typed: "", next: "We need to.") == .init(backspaces: 0, text: "We need to."))
        #expect(Dictation.mend(typed: "We need to.", next: "Improve the screens.") == .init(backspaces: 1, text: " improve the screens."))
        #expect(Dictation.mend(typed: "Done.", next: "Next thing.") == .init(backspaces: 0, text: " Next thing."))
        #expect(Dictation.mend(typed: "We need to.", next: "I think so.") == .init(backspaces: 1, text: " I think so."))
        #expect(Dictation.mend(typed: "Done.", next: "Um.") == .init(backspaces: 0, text: ""))
    }

    @Test func recoveryPhrases() {
        #expect(Dictation.recovery(in: "That was a command.") == .wasCommand)
        #expect(Dictation.recovery(in: "Do that instead") == .wasCommand)
        #expect(Dictation.recovery(in: "No, type that instead") == .typeInstead)
        #expect(Dictation.recovery(in: "Scratch that.") == .scratchThat)
        #expect(Dictation.recovery(in: "Type it") == .typeKept(about: nil))
        #expect(Dictation.recovery(in: "paste it here please") == .typeKept(about: nil))
        #expect(Dictation.recovery(in: "Copy it.") == .copyKept(about: nil))
        #expect(Dictation.recovery(in: "What did you keep?") == .listKept)
        #expect(Dictation.recovery(in: "Type the last one") == .typeKept(about: nil))
        #expect(Dictation.recovery(in: "Type the one about the deck") == .typeKept(about: "the deck"))
        #expect(Dictation.recovery(in: "copy the bit about pricing") == .copyKept(about: "pricing"))
        // Inside a sentence they're content.
        #expect(Dictation.recovery(in: "and that was a command line tool we built last year") == nil)
        #expect(Dictation.recovery(in: "Type that instead of the old heading in the doc") == nil)
        #expect(Dictation.recovery(in: "We should scratch that idea") == nil)
    }

    @Test func neverMindOnlyErasesAFreshRun() {
        #expect(Dictation.cancelEffect(of: "never mind", runAge: 1.5) == .erase)
        #expect(Dictation.cancelEffect(of: "never mind", runAge: 12) == .keep)
        #expect(Dictation.cancelEffect(of: "Cancel that.", runAge: 4) == .keep)
        #expect(Dictation.cancelEffect(of: "Cancel dictation", runAge: 60) == .erase)
    }

    /// 9 Nov row 453: "…Send this message." ended the dictation in the router; now locally too.
    @Test func sendThisMessage() {
        #expect(Dictation.endCommand(in: "maybe find some other options. Send this message.") == ("maybe find some other options", .send))
        #expect(Dictation.endCommand(in: "Send this.") == ("", .send))
    }
}

/// Deterministic random numbers for the fuzz test.
struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next(_ upper: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(max(upper, 1)))
    }
}
