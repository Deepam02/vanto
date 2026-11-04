import AppKit
import VoiceCommandCore

enum UndoAction {
    case refocus(pid: pid_t)
    case chromeTab(windowID: Int, tabID: Int)
    case closeChromeTab(windowID: Int, tabID: Int, thenShow: (Int, Int)?)
    case reopenURL(String)
    case deleteTyped(chars: Int)
    case restoreDraft(original: String)
}

enum ExecOutcome {
    case ok(String, undo: UndoAction?)
    case fail(String)

    var succeeded: Bool { if case .ok = self { return true }; return false }
    var message: String { switch self { case .ok(let m, _): return m; case .fail(let m): return m } }
}

/// Runs validated tool calls on the Mac. One adapter per tool family; each verifies its
/// own result before reporting success. Owns the open draft and the undo stack.
@MainActor
final class Executor {
    struct Draft {
        enum Target {
            case element(TextInputResolver.Target)
            case terminal(DesktopSnapshot.TerminalSession)
            /// Pasted into an app whose text box Accessibility can't see (Claude, some Electron
            /// apps): tracked by app only.
            case blind(pid: pid_t)
        }
        var target: Target
        var appName: String
        var typedText: String = ""
        var typedChars: Int = 0
        var lastInsertAt = Date()
        var hint: AppHint?

        var targetDescription: String {
            switch target {
            case .element: return "chat_box"
            case .terminal(let s): return "terminal \(s.id)\(s.running.map { " (running \($0))" } ?? "")"
            case .blind: return "focused"
            }
        }
    }

    private(set) var draft: Draft?
    private var undoStack: [UndoAction] = []
    private var scroller: Task<Void, Never>?

    /// Scroll a little every 120 ms until `stopScrolling` (any speech) or 30 s.
    private func startScrolling(_ direction: ScrollDirection) {
        scroller?.cancel()
        let point = AppWindowAdapter.frontWindowCenter()
        scroller = Task { @MainActor in
            let until = Date().addingTimeInterval(30)
            while !Task.isCancelled, Date() < until {
                KeyPresser.scroll(direction, page: false, at: point)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    func stopScrolling() {
        scroller?.cancel()
        scroller = nil
    }

    /// The card the last describe_screen produced, for the HUD.
    var lastCard: HelpCard?
    /// A held terminal command typed into its session but not run yet (type, then confirm).
    private(set) var pretyped: (session: DesktopSnapshot.TerminalSession, command: String)?
    var hints: AppHints
    private let snapshots: SnapshotBuilder

    init(hints: AppHints, snapshots: SnapshotBuilder) {
        self.hints = hints
        self.snapshots = snapshots
    }

    func endSession() {
        stopScrolling()
        draft = nil
        pretyped = nil
        undoStack.removeAll()
    }

    var draftForRouter: RouterInput.Draft? {
        draft.map { RouterInput.Draft(app: $0.appName, target: $0.targetDescription, typedText: $0.typedText) }
    }

    /// Execute one action tool. Control tools (wait, ignore, say, end, confirm, cancel)
    /// are handled by the session controller.
    func execute(_ call: ToolCall) async -> ExecOutcome {
        let snap = snapshots.snapshot
        snapshots.markDirty()
        let outcome: ExecOutcome
        switch call {
        case .openApp(let app):
            outcome = await AppWindowAdapter.openApp(app, snapshot: snap)
        case .focusWindow(let id):
            outcome = await AppWindowAdapter.focusWindow(id, snapshot: snap, elements: snapshots.windowElements)
        case .browserSwitchTab(let id):
            guard let tab = snap.tab(id) else { return .fail("That tab isn't open any more") }
            outcome = await BrowserAdapter.switchTab(tab)
        case .browserOpenURL(let url, let newTab):
            outcome = await BrowserAdapter.openURL(url, newTab: newTab)
        case .browserNewTab:
            outcome = await BrowserAdapter.newTab()
        case .browserCloseTab(let id):
            guard let tab = snap.tab(id) else { return .fail("That tab isn't open any more") }
            outcome = await BrowserAdapter.closeTab(tab)
        case .browserNavigate(let action):
            outcome = await BrowserAdapter.navigate(action)
        case .browserSearch(let query):
            outcome = await BrowserAdapter.search(query)
        case .terminalFocus(let id):
            guard let s = snap.terminal(id) else { return .fail("That terminal session isn't open") }
            outcome = await TerminalAdapter.focus(s)
        case .terminalNew(let cwd):
            let app = preferredTerminalApp(snap)
            outcome = await TerminalAdapter.newTab(app: app, cwd: cwd)
        case .terminalRun(let id, let command, _, _):
            guard let s = snap.terminal(id) else { return .fail("That terminal session isn't open") }
            outcome = await TerminalAdapter.run(s, command)
        case .typeText(let target, let app, let sessionID, let payload):
            outcome = await typeText(target: target, app: app, sessionID: sessionID, payload: payload, snap: snap)
        case .newline:
            outcome = await newline()
        case .clearTyped:
            outcome = await clearTyped()
        case .submit:
            outcome = await submit()
        case .pressKeys(let keys):
            outcome = KeyPresser.press(keys) ? .ok("Pressed \(keys)", undo: nil) : .fail("Couldn't press \(keys)")
        case .scroll(let direction, .continuous):
            startScrolling(direction)
            outcome = .ok("Scrolling \(direction.rawValue) — say anything to stop", undo: nil)
        case .scroll(let direction, let amount):
            KeyPresser.scroll(direction, page: amount == .page, at: AppWindowAdapter.frontWindowCenter())
            outcome = .ok("Scrolled \(direction.rawValue)", undo: nil)
        case .undoLast:
            outcome = await undoLast()
        case .menuCommand(let item, let menu):
            outcome = await UIAdapter.menuCommand(item: item, menu: menu)
        case .clickElement(let name):
            outcome = await UIAdapter.click(name: name)
        case .focusTextBox(let app):
            outcome = await UIAdapter.focusTextBox(app: app, hints: hints, snapshot: snap)
        case .describeScreen:
            let (summary, card) = await UIAdapter.describe()
            lastCard = card
            outcome = card == nil ? .fail(summary) : .ok(summary, undo: nil)
        case .rewriteDraft(let text):
            outcome = await rewriteDraft(text)
        default:
            outcome = .fail("\(call.name) is not an action")
        }
        if case .ok(_, let undo?) = outcome {
            undoStack.append(undo)
            if undoStack.count > 20 { undoStack.removeFirst() }
        }
        return outcome
    }

    var canUndo: Bool { !undoStack.isEmpty }

    // MARK: Typing

    /// Hold-Fn dictation: paste into whatever has focus, like any dictation tool, but never
    /// into a password field. Electron apps (Slack, Cursor's chat) often don't report an
    /// editable field, so when none is detected it still pastes and also leaves the text on
    /// the clipboard: if the paste went nowhere, nothing is lost.
    func dictate(_ text: String) async -> ExecOutcome {
        let focused = AX.focusedElement()
        if let focused, AX.isSecure(focused) { return .fail("That's a password field — not typing") }
        let front = NSWorkspace.shared.frontmostApplication
        let name = front?.localizedName ?? "the front app"
        let terminals = [TerminalSessions.terminalBundleID, TerminalSessions.itermBundleID, TerminalSessions.ghosttyBundleID]
        let sure = terminals.contains(front?.bundleIdentifier ?? "") || focused.map { AX.isEditable($0) } == true
        await PasteService.paste(text)
        if sure { return .ok("Typed into \(name)", undo: nil) }
        PasteService.copy(text)
        return .ok("Typed into \(name), and copied in case it didn't land", undo: nil)
    }

    private func preferredTerminalApp(_ snap: DesktopSnapshot) -> DesktopSnapshot.TerminalApp {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if front == TerminalSessions.ghosttyBundleID { return .ghostty }
        if front == TerminalSessions.itermBundleID { return .iterm2 }
        if front == TerminalSessions.terminalBundleID { return .terminal }
        if let s = snap.terminals.first(where: \.selected) ?? snap.terminals.first { return s.app }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalSessions.ghosttyBundleID) != nil { return .ghostty }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalSessions.itermBundleID) != nil { return .iterm2 }
        return .terminal
    }

    private func typeText(target: TypeTarget, app: String?, sessionID: String?, payload: String, snap: DesktopSnapshot) async -> ExecOutcome {
        switch target {
        case .terminal:
            guard let sid = sessionID, let s = snap.terminal(sid) else { return .fail("No terminal session to type into") }
            return await typeIntoTerminal(s, payload)

        case .focused:
            // A terminal in front: type into its visible session.
            if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
               [TerminalSessions.terminalBundleID, TerminalSessions.itermBundleID, TerminalSessions.ghosttyBundleID].contains(front),
               let s = snap.terminals.first(where: { $0.selected && TerminalAdapter.bundleID($0.app) == front }) {
                return await typeIntoTerminal(s, payload)
            }
            do {
                guard let front = NSWorkspace.shared.frontmostApplication else { return .fail("No app in front") }
                let pid = front.processIdentifier
                var el = try TextInputResolver.focusedEditable(in: pid)
                if el == nil {
                    // Electron apps hide their text boxes until asked (4 Nov, Claude desktop).
                    await UIAdapter.exposeTree(front)
                    el = try TextInputResolver.focusedEditable(in: pid)
                }
                if el == nil, let box = TextInputResolver.bestCandidate(pid: pid, label: nil),
                   (try? await TextInputResolver.focus(box, pid: pid)) == true {
                    // Focus wasn't in a box: use the app's message box (4 Nov, Slack pasted blind).
                    el = try TextInputResolver.focusedEditable(in: pid)
                }
                guard let el else { return await typeBlind(into: front, payload) }
                let t = TextInputResolver.Target(pid: pid, element: el, appName: front.localizedName ?? "?", bundleID: front.bundleIdentifier)
                return await typeIntoElement(t, payload)
            } catch {
                return .fail("\(error)")
            }

        case .chat_box:
            // Continue an open draft in the same app.
            if let d = draft, case .element(let t) = d.target, app == nil || t.appName.lowercased().contains(app!.lowercased()) || app!.lowercased().contains(t.appName.lowercased()) {
                guard await refocus(t) else { return .fail("The draft's text box is gone — nothing typed") }
                return await typeIntoElement(t, payload)
            }
            guard let app else { return await typeText(target: .focused, app: nil, sessionID: nil, payload: payload, snap: snap) }
            // A chat_box request for a terminal app means its visible session.
            if let h = hints.hint(named: app), h.focus == .terminal,
               let s = snap.terminals.first(where: { $0.selected && h.bundleIDs.contains(TerminalAdapter.bundleID($0.app)) }) {
                return await typeIntoTerminal(s, payload)
            }
            do {
                let t = try await TextInputResolver.resolveChatBox(appQuery: app, hints: hints, snapshot: snap)
                return await typeIntoElement(t, payload)
            } catch TextInputResolver.Failure.noInput {
                // The app is in front but its box is hidden from Accessibility: paste anyway.
                guard let front = NSWorkspace.shared.frontmostApplication else { return .fail("Couldn't find a text box") }
                return await typeBlind(into: front, payload)
            } catch {
                return .fail("\(error)")
            }
        }
    }

    /// Paste where the keyboard focus is when no text box can be seen, and keep a copy on
    /// the clipboard: a failed type never loses the words (4 Nov). Never into a password field.
    private func typeBlind(into app: NSRunningApplication, _ payload: String) async -> ExecOutcome {
        if let f = AX.focusedElement(), AX.isSecure(f) { return .fail("That's a password field — not typing") }
        let pid = app.processIdentifier
        var text = payload
        var continuing = false
        if let d = draft, case .blind(let dp) = d.target, dp == pid, d.typedChars > 0 {
            text = " " + payload
            continuing = true
        }
        await PasteService.paste(text)
        PasteService.copy((continuing ? draft!.typedText : "") + text)
        let name = app.localizedName ?? "the front app"
        if !continuing {
            draft = Draft(target: .blind(pid: pid), appName: name, hint: hints.hint(bundleID: app.bundleIdentifier) ?? hints.hint(named: name))
        }
        draft!.typedText += text
        draft!.typedChars += text.count
        draft!.lastInsertAt = Date()
        return .ok("Typed into \(name) (also copied, in case it didn't land) — say “send” to send", undo: .deleteTyped(chars: text.count))
    }

    private func typeIntoTerminal(_ s: DesktopSnapshot.TerminalSession, _ payload: String) async -> ExecOutcome {
        var text = payload
        var continuing = false
        if let d = draft, case .terminal(let ds) = d.target, ds.id == s.id, d.typedChars > 0 {
            text = " " + payload
            continuing = true
        }
        let r = await TerminalAdapter.type(s, text)
        guard r.succeeded else { return r }
        if !continuing {
            draft = Draft(target: .terminal(s), appName: s.running == "claude" ? "Claude Code" : TerminalAdapter.appName(s.app),
                          hint: hints.hint(bundleID: TerminalAdapter.bundleID(s.app)))
        }
        draft!.typedText += text
        draft!.typedChars += text.count
        draft!.lastInsertAt = Date()
        return .ok("Typed into \(draft!.appName) — say “send” to send", undo: .deleteTyped(chars: text.count))
    }

    private func typeIntoElement(_ t: TextInputResolver.Target, _ payload: String) async -> ExecOutcome {
        // Verify before typing: never skipped.
        do {
            guard let el = try TextInputResolver.focusedEditable(in: t.pid) else { return .fail("Focus moved away from \(t.appName) — nothing typed") }
            _ = el
        } catch {
            return .fail("\(error)")
        }
        var text = payload
        var continuing = false
        if let d = draft, case .element(let dt) = d.target, dt.pid == t.pid, CFEqual(dt.element, t.element), d.typedChars > 0 {
            text = " " + payload
            continuing = true
        }
        await PasteService.paste(text)
        if !continuing {
            draft = Draft(target: .element(t), appName: t.appName, hint: hints.hint(bundleID: t.bundleID) ?? hints.hint(named: t.appName))
        }
        draft!.typedText += text
        draft!.typedChars += text.count
        draft!.lastInsertAt = Date()
        return .ok("Typed into \(t.appName) — say “send” to send", undo: .deleteTyped(chars: text.count))
    }

    /// Bring the draft's text box back and confirm focus landed on it.
    private func refocus(_ t: TextInputResolver.Target) async -> Bool {
        if AppWindowAdapter.frontmostPID() != t.pid {
            guard await AppWindowAdapter.refocus(pid: t.pid) else { return false }
        }
        if let focused = try? TextInputResolver.focusedEditable(in: t.pid), CFEqual(focused, t.element) { return true }
        AX.set(t.element, kAXFocusedAttribute, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 80_000_000)
        guard let focused = try? TextInputResolver.focusedEditable(in: t.pid) else { return false }
        if CFEqual(focused, t.element) { return true }
        // Electron may hand back a new wrapper for the same field: accept same role and frame.
        return AX.string(focused, kAXRoleAttribute) == AX.string(t.element, kAXRoleAttribute) &&
            AX.frame(focused) == AX.frame(t.element) && AX.frame(focused) != nil
    }

    private func refocusDraft() async -> Bool {
        guard let d = draft else { return false }
        switch d.target {
        case .element(let t): return await refocus(t)
        case .blind(let pid):
            if AppWindowAdapter.frontmostPID() == pid { return true }
            return await AppWindowAdapter.refocus(pid: pid)
        case .terminal(let s):
            guard case .ok = await TerminalAdapter.focus(s) else { return false }
            return await TerminalAdapter.isFront(s)
        }
    }

    // MARK: Draft actions

    private func submit() async -> ExecOutcome {
        guard let d = draft, !d.typedText.trimmingCharacters(in: .whitespaces).isEmpty else { return .fail("Nothing typed to send") }
        // Submitting safely (Final review 13): refocus the recorded target and re-check it.
        guard await refocusDraft() else { return .fail("The draft's target changed — not sent") }
        // Don't race the paste (Final review 11).
        let since = Date().timeIntervalSince(d.lastInsertAt)
        if since < 0.15 { try? await Task.sleep(nanoseconds: UInt64((0.15 - since) * 1_000_000_000)) }
        let ok: Bool
        switch d.target {
        case .terminal(let s): ok = await TerminalAdapter.pressEnter(s)
        case .element, .blind: ok = KeyPresser.press(d.hint?.submitKey ?? "return")
        }
        guard ok else { return .fail("Couldn't press send") }
        draft = nil
        return .ok("Sent to \(d.appName)", undo: nil)
    }

    private func newline() async -> ExecOutcome {
        guard let d = draft else { return .fail("No draft open") }
        guard await refocusDraft() else { return .fail("The draft's text box is gone") }
        let key = d.hint?.newlineKey ?? "shift+return"
        guard KeyPresser.press(key) else { return .fail("Couldn't insert a line break") }
        draft!.typedText += "\n"
        draft!.typedChars += 1
        draft!.lastInsertAt = Date()
        return .ok("New line", undo: .deleteTyped(chars: 1))
    }

    /// Replace this app's own unsent draft with an edited version ("improve the English").
    /// Undo puts the original back. Never sends.
    private func rewriteDraft(_ text: String) async -> ExecOutcome {
        guard let d = draft, d.typedChars > 0 else { return .fail("No draft to edit") }
        guard await refocusDraft() else { return .fail("The draft's text box is gone") }
        let original = d.typedText
        let fresh = text.replacingOccurrences(of: "[\\r\\n]+$", with: "", options: .regularExpression)
        KeyPresser.backspace(d.typedChars)
        switch d.target {
        case .terminal(let s):
            let r = await TerminalAdapter.type(s, fresh)
            guard r.succeeded else { return r }
        case .element, .blind:
            await PasteService.paste(fresh)
        }
        draft!.typedText = fresh
        draft!.typedChars = fresh.count
        draft!.lastInsertAt = Date()
        undoStack.removeAll { if case .deleteTyped = $0 { return true }; return false }
        return .ok("Edited the draft — say “send” to send, or “undo” for the original", undo: .restoreDraft(original: original))
    }

    // MARK: Type, then confirm (terminal commands that need a yes)

    /// Type a held command into its session without running it, so the person sees exactly
    /// what "yes" will run.
    func pretype(_ call: ToolCall) async -> Bool {
        guard case .terminalRun(let id, let command, _, _) = call, let s = snapshots.snapshot.terminal(id) else { return false }
        guard case .ok = await TerminalAdapter.type(s, command) else { return false }
        pretyped = (s, command)
        return true
    }

    /// "Yes": press Enter on the typed command.
    func runPretyped() async -> ExecOutcome {
        guard let p = pretyped else { return .fail("Nothing typed to run") }
        pretyped = nil
        guard case .ok = await TerminalAdapter.focus(p.session) else { return .fail("That terminal is gone — not run") }
        guard await TerminalAdapter.pressEnter(p.session) else { return .fail("Couldn't press Enter") }
        return .ok("Ran: \(p.command)", undo: nil)
    }

    /// The session is ending with a command still typed: take it back out in the background.
    func abandonPretyped() {
        guard let p = pretyped else { return }
        pretyped = nil
        Task { await Self.clearLine(p.session) }
    }

    /// "No" (or a new command): take the typed command back out. ⌃U clears the whole line
    /// (backspacing by count left commands piling up on 4 Nov).
    func clearPretyped() async {
        guard let p = pretyped else { return }
        pretyped = nil
        snapshots.markDirty()
        await Self.clearLine(p.session)
    }

    /// ⌃U in the terminal, only if that terminal really is in front: in other apps ⌃U
    /// deletes text the person wrote.
    static func clearLine(_ s: DesktopSnapshot.TerminalSession) async {
        guard case .ok = await TerminalAdapter.focus(s),
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == TerminalAdapter.bundleID(s.app) else { return }
        _ = KeyPresser.press("ctrl+u")
    }

    private func clearTyped() async -> ExecOutcome {
        guard let d = draft, d.typedChars > 0 else { return .fail("Nothing typed to clear") }
        guard await refocusDraft() else { return .fail("The draft's text box is gone") }
        KeyPresser.backspace(d.typedChars)
        draft!.typedText = ""
        draft!.typedChars = 0
        undoStack.removeAll { if case .deleteTyped = $0 { return true }; return false }
        return .ok("Cleared what I typed", undo: nil)
    }

    private func undoLast() async -> ExecOutcome {
        guard let action = undoStack.popLast() else { return .fail("Nothing to undo") }
        switch action {
        case .refocus(let pid):
            return await AppWindowAdapter.refocus(pid: pid) ? .ok("Undone", undo: nil) : .fail("Couldn't go back")
        case .chromeTab(let w, let t):
            return await BrowserAdapter.switchTo(windowID: w, tabID: t) ? .ok("Undone", undo: nil) : .fail("Couldn't switch back")
        case .closeChromeTab(let w, let t, let show):
            let tab = DesktopSnapshot.Tab(windowID: w, tabID: t, index: 0, title: "tab", url: "", active: false, frontWindow: false)
            let r = await BrowserAdapter.closeTab(tab)
            if let show { _ = await BrowserAdapter.switchTo(windowID: show.0, tabID: show.1) }
            return r.succeeded ? .ok("Undone", undo: nil) : r
        case .reopenURL(let url):
            let r = await BrowserAdapter.openURL(url, newTab: true)
            return r.succeeded ? .ok("Reopened the tab", undo: nil) : r
        case .deleteTyped(let chars):
            guard draft != nil else { return .fail("The draft is gone") }
            guard await refocusDraft() else { return .fail("The draft's text box is gone") }
            KeyPresser.backspace(chars)
            draft!.typedChars = max(0, draft!.typedChars - chars)
            draft!.typedText = String(draft!.typedText.dropLast(chars))
            return .ok("Removed that text", undo: nil)
        case .restoreDraft(let original):
            guard let d = draft else { return .fail("The draft is gone") }
            guard await refocusDraft() else { return .fail("The draft's text box is gone") }
            KeyPresser.backspace(d.typedChars)
            if case .terminal(let s) = d.target { _ = await TerminalAdapter.type(s, original) } else { await PasteService.paste(original) }
            draft!.typedText = original
            draft!.typedChars = original.count
            return .ok("Back to the original draft", undo: nil)
        }
    }
}
