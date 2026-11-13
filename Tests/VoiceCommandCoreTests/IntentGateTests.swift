import Foundation
import Testing
@testable import VoiceCommandCore

/// The intent gate on real speech (docs/specs/never-lose-dictation.md §7): the 3–4 and 9 Nov
/// logs, hand-labelled, plus written persona examples (Tools/intent-eval).
@Suite struct IntentGateLabelledTests {
    struct Case: Decodable { let id: String; let text: String; let label: String }
    struct File: Decodable { let cases: [Case] }

    static let cases: [Case] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/intent-eval/labelled-utterances.json")
        return (try? JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases) ?? []
    }()

    static let field = IntentContext(focus: .textField(app: "Slack"))
    static let prompt = IntentContext(focus: .assistantPrompt(app: "Claude Code"))

    @Test func loads() {
        #expect(Self.cases.count > 400)
        #expect(Self.cases.filter { $0.label == "dictation" }.count >= 20)
    }

    /// The hard rule, one way: no command is ever typed without the router, whatever is focused.
    @Test func noCommandIsCertainDictation() {
        for c in Self.cases where c.label == "command" {
            for ctx in [Self.field, Self.prompt] {
                let d = IntentGate.decide(c.text, ctx)
                if case .dictate = d.route { Issue.record("\(c.id) typed in \(ctx.focus.label): \(c.text) — \(d.reason)") }
            }
        }
    }

    /// …and the other: no dictation is ever a certain command.
    @Test func noDictationIsCertainCommand() {
        for c in Self.cases where c.label == "dictation" {
            for ctx in [Self.field, Self.prompt, IntentContext()] {
                let d = IntentGate.decide(c.text, ctx)
                if case .command = d.route { Issue.record("\(c.id) certain command in \(ctx.focus.label): \(c.text) — \(d.reason)") }
            }
        }
    }

    /// Background speech is never typed, and with media playing it's kept unless it carries a cue.
    @Test func backgroundIsNeverTyped() {
        var media = Self.field
        media.mediaPlaying = true
        for c in Self.cases where c.label == "background" {
            for ctx in [Self.field, media] {
                if case .dictate = IntentGate.decide(c.text, ctx).route { Issue.record("\(c.id) typed: \(c.text)") }
            }
        }
    }

    /// Most long dictation is decided on the device; the rest goes to the router, not lost.
    @Test func longDictationIsCaughtLocally() {
        let long = Self.cases.filter { $0.label == "dictation" && TextMatching.words($0.text).count >= IntentGate.minDictationWords }
        let local = long.filter {
            if case .dictate = IntentGate.decide($0.text, Self.prompt).route { return true }
            return false
        }
        #expect(local.count * 10 >= long.count * 7, "only \(local.count) of \(long.count) caught locally")
    }

    /// Most short commands are certain on the device (logged as such; the router still runs them).
    @Test func shortCommandsAreCertain() {
        let short = Self.cases.filter { $0.label == "command" && TextMatching.words($0.text).count <= 6 }
        let certain = short.filter {
            if case .command = IntentGate.decide($0.text, Self.field).route { return true }
            return false
        }
        #expect(certain.count * 2 >= short.count, "only \(certain.count) of \(short.count)")
    }
}

/// The 3–4 Nov failures the spec replays (§7.3).
@Suite struct IntentGateReplayTests {
    static let claudeCode = IntentContext(focus: .assistantPrompt(app: "Claude Code"))

    /// 321–323: 60 words of plain speech were thrown away by `ignore`.
    @Test func plainSpeechIntoClaudeCodeIsTyped() {
        let said = "At the end of the day, I think we have to build a Products which is for any person, not a technical guy, but maybe even non-technical persons like PMs or everyday users, like marketing people or maybe editors, like it should work for any and all category of people. That's how we will grow it into a different."
        let d = IntentGate.decide(said, Self.claudeCode)
        #expect(d.route == .dictate(text: said, target: nil, start: .implicit))
        #expect(d.step == .local)
        #expect(d.logLine.hasPrefix("local: certain dictation (assistant prompt (Claude Code)"))
        // In a plain shell, or with nothing focused, it goes to the router instead.
        #expect(IntentGate.decide(said, IntentContext(focus: .shell(session: "zsh"))).route == .router)
        #expect(IntentGate.decide(said, IntentContext(focus: .none)).route == .router)
        #expect(IntentGate.decide(said, IntentContext(focus: .secure)).route == .router)
    }

    /// 314–315: "Enter into dictation [Claude] Code" asked "which app?" twice.
    @Test func enterDictationStartsLocally() {
        let d = IntentGate.decide("Enter into dictation Code.", IntentContext(focus: .shell(session: "zsh")))
        #expect(d.route == .dictate(text: "", target: "Code", start: .spoken))
        #expect(d.step == .explicitStart)
        #expect(IntentGate.explicitStart("enter dictation into Claude Code") == .init(text: "", target: "Claude Code", verb: "enter dictation"))
        #expect(IntentGate.explicitStart("Start dictating into Claude Code, we need to fix the tests")
            == .init(text: "we need to fix the tests", target: "Claude Code", verb: "enter dictation"))
    }

    /// 151–152: a complaint to Vanto was typed into the terminal.
    @Test func complaintToVantoIsNotTyped() {
        let said = "Don't clear it by a clear. I mean, can you like you have added an unknown command, you have added an MKDIR command, you have added a clear command. So, can you just remove all of them?"
        if case .dictate = IntentGate.decide(said, Self.claudeCode).route { Issue.record("typed") }
    }

    /// 296–299: Netflix dialogue is kept silently.
    @Test func videoDialogueIsKept() {
        var ctx = IntentContext(focus: .textField(app: "Google Chrome"))
        ctx.mediaPlaying = true
        let d = IntentGate.decide("Welcome to Aratus. YouTube the Imperial Ecologist. Thank you for the still seats.", ctx)
        #expect(d.route == .keep(.noise))
        // A command over the video still goes through.
        #expect(IntentGate.decide("Pause the video.", ctx).route == .command(text: "Pause the video."))
        // So does a follow-up right after speaking to Vanto.
        ctx.sinceSpokeToVanto = 4
        #expect(IntentGate.decide("The other one with the red thumbnail", ctx).route == .router)
    }
}

@Suite struct IntentGateRuleTests {
    @Test func holdFnIsAlwaysDictation() {
        let d = IntentGate.decide("open Slack", IntentContext(holdFn: true))
        #expect(d.route == .dictate(text: "open Slack", target: nil, start: .holdFn))
        #expect(d.source == .holdFn)
    }

    @Test func vantoPrefixIsACommand() {
        #expect(IntentGate.addressedToVanto("Vanto, open Slack") == "open Slack")
        #expect(IntentGate.addressedToVanto("Hey Vanto open Slack") == "open Slack")
        #expect(IntentGate.addressedToVanto("Vanto is a voice tool for everyone") == nil)
        // It escapes a run too.
        let d = IntentGate.decide("Vanto, switch to Chrome", IntentContext(runActive: true))
        #expect(d.route == .command(text: "switch to Chrome"))
        #expect(d.step == .forced)
    }

    @Test func runContinuesUnlessItEndsOrIsClearlyACommand() {
        let run = IntentContext(focus: .assistantPrompt(app: "Claude Code"), runActive: true, runTarget: "Claude Code")
        #expect(IntentGate.decide("and also check the onboarding copy", run).route
            == .dictate(text: "and also check the onboarding copy", target: "Claude Code", start: .continuing))
        #expect(IntentGate.decide("When should we introduce the sidebar. Send it.", run).route
            == .endRun(content: "When should we introduce the sidebar", end: .send))
        #expect(IntentGate.decide("Switch to Chrome.", run).route == .router)
        // "…we should" + "close the deal by Friday": mid-sentence, so it's content.
        var mid = run
        mid.runEndsMidSentence = true
        if case .dictate = IntentGate.decide("close the deal by Friday", mid).route {} else { Issue.record("not typed") }
    }

    @Test func explicitStarts() {
        func start(_ s: String) -> IntentGate.ExplicitStart? { IntentGate.explicitStart(s) }
        #expect(start("Type a Messages saying yeah, push it for me")?.text == "yeah, push it for me")
        #expect(start("Type in a message saying I want to go with the I want to find more better options.")?.text
            == "I want to go with the I want to find more better options.")
        #expect(start("Can you write a message saying like? I want to go with Voice AI Native Task Orchestrator.")?.text
            == "I want to go with Voice AI Native Task Orchestrator.")
        #expect(start("Take a note that the demo moved to Friday")?.text == "the demo moved to Friday")
        #expect(start("Dictate into Claude Code")?.target == "Claude Code")
        #expect(start("type hello world")?.text == "hello world")
        #expect(start("Write this down: buy milk")?.text == "buy milk")
        let slack = start("Type in Slack saying I'll be late")
        #expect(slack?.target == "Slack")
        #expect(slack?.text == "I'll be late")
        // Composing and other requests stay with the router.
        #expect(start("Can you write a very nice post about announcing yourself? You are Vanto") == nil)
        #expect(start("Write that we should end the session early") == nil)
        #expect(start("Can you dictate a Messages for him?") == nil)
        #expect(start("Type a message to Priya") == nil)
        #expect(start("Make a post something like Hey guys") == nil)
        #expect(start("type that") == nil)
    }

    @Test func noteThatIsContentInAPrompt() {
        let said = "Note that the API changed last week"
        #expect(IntentGate.decide(said, IntentContext(focus: .textField(app: "Notes"))).route
            == .dictate(text: "the API changed last week", target: nil, start: .spoken))
        #expect(IntentGate.decide(said, IntentContext(focus: .assistantPrompt(app: "Claude"))).route
            == .dictate(text: said, target: nil, start: .spoken))
    }

    @Test func recoveryNeedsSomethingToRecover() {
        let typed = IntentContext(focus: .textField(app: "Slack"), typedRecently: true)
        #expect(IntentGate.decide("That was a command.", typed).route == .recover(.wasCommand))
        #expect(IntentGate.decide("No, scratch that", typed).route == .recover(.scratchThat))
        #expect(IntentGate.decide("Copy it", IntentContext(hasKept: true)).route == .recover(.copyKept(about: nil)))
        // With nothing kept, "copy it" is an ordinary command.
        #expect(IntentGate.decide("Copy it", IntentContext(focus: .textField(app: "Notes"))).route == .command(text: "Copy it"))
        #expect(IntentGate.decide("What did you keep?", IntentContext()).route == .recover(.listKept))
    }

    @Test func shortAnswerToVanto() {
        let ctx = IntentContext(focus: .textField(app: "Slack"), vantoJustAsked: true)
        #expect(IntentGate.decide("Yes, works for me", ctx).route == .command(text: "Yes, works for me"))
        #expect(IntentGate.decide("Yes, works for me", IntentContext(focus: .textField(app: "Slack"))).route == .router)
    }

    @Test func promptsAreNeverCertainCommands() {
        let ctx = IntentContext(focus: .assistantPrompt(app: "Claude Code"))
        #expect(IntentGate.decide("Can you fix the failing tests", ctx).route == .router)
        #expect(IntentGate.decide("Can you fix the failing tests", IntentContext(focus: .textField(app: "Notes"))).route
            == .command(text: "Can you fix the failing tests"))
    }

    @Test func draftOpenGoesToTheRouter() {
        let said = "I think we should move the launch to next Thursday because the onboarding flow still has rough edges."
        var ctx = IntentContext(focus: .textField(app: "Slack"))
        if case .dictate = IntentGate.decide(said, ctx).route {} else { Issue.record("not typed") }
        ctx.draftOpen = true
        #expect(IntentGate.decide(said, ctx).route == .router)
    }

    @Test func focusFromSnapshot() {
        var snap = DesktopSnapshot(apps: [.init(name: "Ghostty", bundleID: "com.mitchellh.ghostty", pid: 1, frontmost: true)],
                                   terminals: [.init(app: .ghostty, nativeID: "1", title: "zsh", running: "claude", selected: true)])
        #expect(FocusKind.from(snap) == .assistantPrompt(app: "Claude Code"))
        snap.terminals[0].running = nil
        #expect(FocusKind.from(snap) == .shell(session: "zsh"))
        snap = DesktopSnapshot(apps: [.init(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", pid: 2, frontmost: true)],
                               focused: .init(app: "Slack", role: "AXTextArea", editable: true, secure: false))
        #expect(FocusKind.from(snap) == .textField(app: "Slack"))
        snap.focused?.secure = true
        #expect(FocusKind.from(snap) == .secure)
        snap = DesktopSnapshot(apps: [.init(name: "Google Chrome", bundleID: "com.google.Chrome", pid: 3, frontmost: true)],
                               tabs: [.init(windowID: 1, tabID: 1, index: 1, title: "Claude", url: "https://claude.ai/new", active: true, frontWindow: true)],
                               focused: .init(app: "Google Chrome", role: "AXTextArea", editable: true, secure: false))
        #expect(FocusKind.from(snap) == .assistantPrompt(app: "Google Chrome"))
        snap.focused = nil
        #expect(FocusKind.from(snap) == FocusKind.none)
    }
}
