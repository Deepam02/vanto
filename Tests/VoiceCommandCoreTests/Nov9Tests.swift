import Foundation
import Testing
@testable import VoiceCommandCore

/// The 9 Nov sessions (docs/plans/2026-11-09-session-fixes.md).
@Suite struct Nov9VocabularyTests {
    /// "percent" → "Vercel", "make the" → "Mkdir", "message" → "Messages".
    @Test func everydayWordsAreNotBoosted() {
        #expect(!ScreenVocabulary.base.contains("Vercel"))
        let aliases = ScreenVocabulary.spokenAliases.flatMap(\.1)
        #expect(!aliases.contains { $0.hasPrefix("make") })
        #expect(!ScreenVocabulary.spokenAliases.map(\.0).contains("mkdir"))
        let apps = ScreenVocabulary.appTerms(["Messages", "Notes", "Cursor", "Ghostty", "Google Chrome", "Mail", "Claude"])
        #expect(apps == ["Cursor", "Ghostty", "Google Chrome", "Claude"])
    }

    @Test func rawTranscriptKeptOnlyWhenBoostingChangedIt() {
        var b = TranscriptBuffer()
        b.append("Increase the volume.")
        #expect(b.latestRaw == nil)
        b.append("Type a Messages saying hi", raw: "Type a message saying hi")
        #expect(b.latestRaw == "Increase the volume. Type a message saying hi")
        #expect(b.latest == "Increase the volume. Type a Messages saying hi")
    }
}

@Suite struct Nov9SessionEndTests {
    @Test func explicitEndAtTheEndOfTheTranscript() {
        #expect(SessionPhrases.endsSession("Henderson. Uh End the session."))
        #expect(SessionPhrases.endsSession("Nah, you are still not getting it. Close the session."))
        #expect(SessionPhrases.endsSession("okay, end the session please"))
        #expect(SessionPhrases.endsSession("Stop listening."))
    }

    @Test func notAnEndRequest() {
        #expect(!SessionPhrases.endsSession("don't end the session yet"))
        #expect(!SessionPhrases.endsSession("end the session after this video"))
        #expect(!SessionPhrases.endsSession("I want to end the session soon, but first open Slack"))
        #expect(!SessionPhrases.endsSession("stop"))
        #expect(!SessionPhrases.endsSession("that's all"))
        #expect(!SessionPhrases.endsSession("Write that we should end the session early"))
    }
}

@Suite struct Nov9ClickTests {
    @Test func shortcutsInLabels() {
        #expect(ShortcutLabel.parse("Previous (SHIFT+p)")! == ("Previous", "shift+p"))
        #expect(ShortcutLabel.parse("Pause (k)")! == ("Pause", "k"))
        #expect(ShortcutLabel.parse("Next keyboard shortcut SHIFT+n")! == ("Next", "shift+n"))
        #expect(ShortcutLabel.parse("(13) Tu Hain Toh") == nil)
        #expect(ShortcutLabel.parse("Inbox (3)") == nil)
        #expect(ShortcutLabel.parse("Post") == nil)
        #expect(ShortcutLabel.parse("Send (Return)") == nil)
    }

    /// YouTube's video links carry title, channel and views in one long name.
    @Test func longVideoNamesStillMatch() {
        let labels = ["Saheba by Artist 1.2M views 3 years ago", "I Am Done (Official Video) by Someone 4.5M views 2 years ago 3 minutes",
                      "Finding Her by Kushagra 10M views 1 year ago"]
        #expect(NameMatch.best("I am done", in: labels) == 1)
    }
}

@Suite struct Nov9PolicyTests {
    func ctx(_ t: String, draft: Bool = false) -> PolicyContext {
        PolicyContext(transcript: t, snapshot: DesktopSnapshot(), draftOpen: draft, draftText: draft ? "hi" : "")
    }

    @Test func composedTextOnlyWhenTheyAskForWriting() {
        let post = "Excited to announce Vanto, a voice layer for your Mac."
        let asked = ActionPolicy.evaluate(.typeText(target: .focused, app: nil, sessionID: nil, payload: post, source: .composed),
                                          context: ctx("Can you write a very nice post about announcing yourself? You are Vanto"))
        guard case .run(.typeText(_, _, _, let p, .composed), _, _) = asked else { Issue.record("expected run, got \(asked)"); return }
        #expect(p == post)

        let notAsked = ActionPolicy.evaluate(.typeText(target: .focused, app: nil, sessionID: nil, payload: post, source: .composed),
                                             context: ctx("open the post"))
        #expect(notAsked.isReject)
        let terminal = ActionPolicy.evaluate(.typeText(target: .terminal, app: nil, sessionID: nil, payload: "rm -rf build", source: .composed),
                                             context: ctx("write a command to clean up"))
        #expect(terminal.isReject)
        // Verbatim is as strict as before.
        #expect(ActionPolicy.evaluate(.typeText(target: .focused, app: nil, sessionID: nil, payload: post), context: ctx("write a post")).isReject)
    }

    @Test func composedTextIsNeverSentInTheSameReply() {
        let d = ActionPolicy.evaluate([
            .typeText(target: .focused, app: nil, sessionID: nil, payload: "Hello everyone", source: .composed),
            .submit(app: nil, sendPhrase: "send it"),
        ], context: ctx("write a nice hello to everyone and send it"))
        #expect(d[1].isReject)
    }

    /// 412: "Go back" → clear_typed and undo_last; the undo took back the action before too.
    @Test func oneRemovalPerRequest() {
        let d = ActionPolicy.evaluate([.clearTyped, .undoLast], context: ctx("Go back. I think your drafting feature is still not good.", draft: true))
        #expect(d[0] == .run(.clearTyped, minPauseMs: 0, note: nil))
        if case .skip = d[1] {} else { Issue.record("expected skip, got \(d[1])") }
        // Undo on its own still runs.
        #expect(ActionPolicy.evaluate([.undoLast], context: ctx("undo that"))[0] == .run(.undoLast, minPauseMs: 0, note: nil))
    }
}

@Suite struct Nov9RouterTests {
    @Test func newArgumentsParse() throws {
        #expect(try ToolCall.parse(name: "look_again", inputJSON: #"{"reason":"open the video"}"#) == .lookAgain)
        #expect(try ToolCall.parse(name: "browser_search", inputJSON: #"{"query":"senorita","here":true}"#) == .browserSearch(query: "senorita", here: true))
        #expect(try ToolCall.parse(name: "browser_search", inputJSON: #"{"query":"news"}"#) == .browserSearch(query: "news", here: false))
        #expect(try ToolCall.parse(name: "click_element", inputJSON: #"{"name":"Post","near":"main"}"#) == .clickElement(name: "Post", near: "main"))
        #expect(try ToolCall.parse(name: "type_text", inputJSON: #"{"target":"focused","payload":"hi","source":"composed"}"#)
                == .typeText(target: .focused, app: nil, sessionID: nil, payload: "hi", source: .composed))
        #expect(try ToolCall.parse(name: "type_text", inputJSON: #"{"target":"focused","payload":"hi"}"#)
                == .typeText(target: .focused, app: nil, sessionID: nil, payload: "hi", source: .verbatim))
        #expect(ToolSchemas.names.contains("look_again"))
    }

    @Test func previousTabIsMarked() {
        var snap = DesktopSnapshot(tabs: [
            .init(windowID: 1, tabID: 10, index: 1, title: "Netflix", url: "https://netflix.com", active: false, frontWindow: true),
            .init(windowID: 1, tabID: 11, index: 2, title: "YouTube", url: "https://youtube.com", active: false, frontWindow: true),
            .init(windowID: 1, tabID: 12, index: 3, title: "Google Search", url: "https://google.com", active: true, frontWindow: true),
        ])
        snap.recentTabIDs = ["chrome:1:12", "chrome:1:11", "chrome:1:10"]
        #expect(snap.previousTab?.title == "YouTube")
        let text = snap.renderForPrompt(transcript: "go back to the previous tab")
        #expect(text.contains("\"YouTube\" | https://youtube.com [previous"))
        #expect(!text.contains("\"Netflix\" | https://netflix.com [previous"))
    }

    @Test func alreadyDoneIsShownAfterLookingAgain() {
        let input = RouterInput(history: "(no commands yet this session)", snapshot: DesktopSnapshot(), transcript: "go to YouTube and open the video",
                                alreadyDone: ["browser_switch_tab(chrome:1:11) → ok", "look_again"])
        let msg = RouterPrompt.userMessage(input)
        #expect(msg.contains("<already_done_for_this_transcript>\n- browser_switch_tab(chrome:1:11) → ok\n- look_again"))
        #expect(!RouterPrompt.userMessage(RouterInput(history: "", snapshot: DesktopSnapshot(), transcript: "x")).contains("already_done"))
    }
}
