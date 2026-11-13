import Testing
@testable import VoiceCommandCore

@Suite struct NameMatchTests {
    @Test func spokenNamesFindLabels() {
        #expect(NameMatch.score("zoom out", "Zoom Out") == 1)
        #expect(NameMatch.best("go to the conversations tab", in: ["Overview", "Conversations", "Limits", "Settings"]) == 1)
        #expect(NameMatch.best("the limits part", in: ["Overview", "Conversations", "Limits"]) == 2)
        #expect(NameMatch.best("zoom out", in: ["Zoom In", "Zoom Out", "Zoom to Fit"]) == 1)
        #expect(NameMatch.best("new window", in: ["New Tab", "New Window", "New Incognito Window"]) == 1)
    }

    /// 4 Nov: names the speech model misspelled, and a chat next to its own "More options".
    @Test func soundAlikeAndContainedLabels() {
        #expect(NameMatch.best("Blue IO", in: ["GitHub", "Blooio", "Gmail"]) == 1)
        #expect(NameMatch.best("clawed", in: ["Chrome", "Claude", "Slack"]) == 1)
        #expect(NameMatch.best("Competitor Website Screenshot", in: [
            "Competitor website screenshots for redesign Running",
            "More options for Competitor website screenshots for redesign"]) == 0)
        #expect(NameMatch.phonetic("Blooio") == NameMatch.phonetic("blueio"))
        #expect(!NameMatch.soundsAlike("slack", "stack"))
    }

    @Test func refusesWeakOrTiedMatches() {
        #expect(NameMatch.best("billing", in: ["Overview", "Conversations"]) == nil)
        #expect(NameMatch.best("zoom", in: ["Zoom In", "Zoom Out"]) == nil)
        #expect(NameMatch.best("close", in: ["Close", "Close", "Close All"]) == 0)
    }
}

@Suite struct Phase2PolicyTests {
    @Test func punctuationKeysParse() {
        #expect(KeyCombo.parse("cmd+minus") == KeyCombo(command: true, key: "-"))
        #expect(KeyCombo.parse("cmd+-") == KeyCombo(command: true, key: "-"))
        #expect(KeyCombo.parse("-") == KeyCombo(key: "-"))
        #expect(KeyCombo.parse("cmd--") == KeyCombo(command: true, key: "-"))
        #expect(KeyCombo.parse("cmd+plus") == KeyCombo(command: true, shift: true, key: "="))
        #expect(KeyCombo.parse("cmd+=") == KeyCombo(command: true, key: "="))
        #expect(KeyCombo.parse("shift+1") == KeyCombo(shift: true, key: "1"))
        #expect(KeyCombo.parse("cmd-shift-k") == KeyCombo(command: true, shift: true, key: "k"))
    }

    /// 4 Nov: the router named the Terminal *window* (w3) instead of its session.
    static func terminalSnapshot(preferred: String? = nil) -> DesktopSnapshot {
        var snap = DesktopSnapshot(
            windows: [
                .init(id: "w1", app: "Terminal", pid: 1, title: "Ana-core — ✳ Shopify Connect", index: 0),
                .init(id: "w2", app: "Terminal", pid: 1, title: "deepamgoyal — -zsh — 136×30", index: 1),
            ],
            terminals: [
                .init(app: .terminal, nativeID: "/dev/ttys003", title: "✳ Shopify Connect", running: "claude", selected: true,
                      windowTitle: "Ana-core — ✳ Shopify Connect", visibleInWindow: true),
                .init(app: .terminal, nativeID: "/dev/ttys001", title: "-zsh", selected: false,
                      windowTitle: "deepamgoyal — -zsh — 136×30", visibleInWindow: true),
                .init(app: .terminal, nativeID: "/dev/ttys009", title: "-zsh", selected: false,
                      windowTitle: "Ana-core — ✳ Shopify Connect", visibleInWindow: false),
            ])
        snap.preferredShellID = preferred
        return snap
    }

    @Test func windowIDsResolveToTheirSession() {
        let ctx = PolicyContext(transcript: "run ls", snapshot: Self.terminalSnapshot())
        let d = ActionPolicy.evaluate(.terminalRun(sessionID: "w2", command: "ls", source: .verbatim, risk: .read_only), context: ctx)
        guard case .run(.terminalRun(let sid, _, _, _), _, _) = d else { Issue.record("\(d)"); return }
        #expect(sid == "terminal:ttys001")
        let f = ActionPolicy.evaluate(.terminalFocus(sessionID: "w2"), context: ctx)
        #expect(f == .run(.terminalFocus(sessionID: "terminal:ttys001"), minPauseMs: 0, note: "window w2 → terminal:ttys001"))
    }

    @Test func voiceOpenedTerminalIsTheDefault() {
        let snap = Self.terminalSnapshot(preferred: "terminal:ttys009")
        #expect(ActionPolicy.defaultShell(snap)?.id == "terminal:ttys009")
        #expect(ActionPolicy.defaultShell(Self.terminalSnapshot())?.id == "terminal:ttys001")
    }

    @Test func riskyClicksNeedAYes() {
        let ctx = PolicyContext(transcript: "click delete", snapshot: DesktopSnapshot())
        if case .hold = ActionPolicy.evaluate(.clickElement(name: "Delete project"), context: ctx) {} else { Issue.record("not held") }
        #expect(ActionPolicy.evaluate(.clickElement(name: "Conversations"), context: ctx) == .run(.clickElement(name: "Conversations", near: nil), minPauseMs: 0, note: nil))
        #expect(ActionPolicy.evaluate(.rewriteDraft(text: "Hi"), context: ctx) == .reject("No draft to edit"))
    }

    @Test func dictationKeepsOnlyWordsReallySaid() {
        let ctx = PolicyContext(transcript: "write a message saying hi team, wait for me", snapshot: DesktopSnapshot())
        let d = ActionPolicy.evaluate(.startDictation(target: .focused, app: nil, sessionID: nil, text: "hi team"), context: ctx)
        #expect(d == .run(.startDictation(target: .focused, app: nil, sessionID: nil, text: "hi team"), minPauseMs: 0, note: nil))
        let made = ActionPolicy.evaluate(.startDictation(target: .focused, app: nil, sessionID: nil, text: "Hello everyone"), context: ctx)
        #expect(made == .run(.startDictation(target: .focused, app: nil, sessionID: nil, text: nil), minPauseMs: 0, note: nil))
    }

    @Test func tabsMatchingTheWordsComeFirst() {
        let tabs = (1...50).map { DesktopSnapshot.Tab(windowID: 1, tabID: $0, index: $0, title: "Tab \($0)", url: "https://example.com/\($0)", active: false, frontWindow: true) }
            + [DesktopSnapshot.Tab(windowID: 2, tabID: 99, index: 1, title: "Blooio", url: "https://app.blooio.com/limits", active: false, frontWindow: false)]
        #expect(DesktopSnapshot.rankTabs(tabs, for: "go to the blooio tab").first?.tabID == 99)
        #expect(DesktopSnapshot(tabs: tabs).renderForPrompt(transcript: "go to blooio").contains("chrome:2:99"))
    }
}

@Suite struct VocabularyTests {
    @Test func dictionaryLines() {
        let d = ScreenVocabulary.parseDictionary("Blooio: blue yo, blu io\nLastSeen\n# a comment\n\nAna-core")
        #expect(d.map(\.0) == ["Blooio", "LastSeen", "Ana-core"])
        #expect(d[0].1 == ["blue yo", "blu io"])
        #expect(d[1].1.isEmpty)
    }

    @Test func distinctiveScreenNames() {
        let snap = DesktopSnapshot(
            windows: [.init(id: "w1", app: "Terminal", pid: 1, title: "Ana-core — ✳ Shopify Connect", index: 0)],
            tabs: [
                .init(windowID: 1, tabID: 1, index: 1, title: "Blooio", url: "https://app.blooio.com", active: true, frontWindow: true),
                .init(windowID: 1, tabID: 2, index: 2, title: "Overview | Context.dev", url: "https://context.dev", active: false, frontWindow: true),
                .init(windowID: 1, tabID: 3, index: 3, title: "Feed | LinkedIn", url: "https://linkedin.com", active: false, frontWindow: true),
            ])
        let t = ScreenVocabulary.terms(from: snap)
        #expect(t.contains("Blooio") && t.contains("Context.dev") && t.contains("LinkedIn") && t.contains("Ana-core"))
        #expect(!t.contains("Overview") && !t.contains("Feed"))
    }
}

@Suite struct ConfirmationTests {
    @Test func placeholderCommandsAreRefused() {
        let ctx = PolicyContext(transcript: "create a new directory", snapshot: Phase2PolicyTests.terminalSnapshot())
        let d = ActionPolicy.evaluate(.terminalRun(sessionID: "terminal:ttys001", command: "mkdir <UNKNOWN>", source: .composed, risk: .changes_files), context: ctx)
        #expect(d.isReject)
    }

    /// Switching on a near match is fine; closing one needs a yes.
    @Test func closingASoundAlikeTabAsksFirst() {
        let tabs = [DesktopSnapshot.Tab(windowID: 1, tabID: 1, index: 1, title: "Gmail", url: "https://mail.google.com", active: true, frontWindow: true),
                    DesktopSnapshot.Tab(windowID: 1, tabID: 2, index: 2, title: "Blooio", url: "https://app.blooio.com", active: false, frontWindow: true)]
        let snap = DesktopSnapshot(tabs: tabs)
        let fuzzy = ActionPolicy.evaluate(.browserCloseTab(tabID: "chrome:1:2"), context: PolicyContext(transcript: "close blue u", snapshot: snap))
        if case .hold = fuzzy {} else { Issue.record("\(fuzzy)") }
        let named = ActionPolicy.evaluate(.browserCloseTab(tabID: "chrome:1:2"), context: PolicyContext(transcript: "close the blooio tab", snapshot: snap))
        #expect(!named.isReject)
        if case .run = named {} else { Issue.record("\(named)") }
    }
}
