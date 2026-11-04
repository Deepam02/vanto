import AppKit
import VoiceCommandCore

enum UndoAction {
    case refocus(pid: pid_t)
    case chromeTab(windowID: Int, tabID: Int)
    case closeChromeTab(windowID: Int, tabID: Int, thenShow: (Int, Int)?)
    case reopenURL(String)
    case deleteTyped(chars: Int)
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
            }
        }
    }

    private(set) var draft: Draft?
    private var undoStack: [UndoAction] = []
    var hints: AppHints
    private let snapshots: SnapshotBuilder

    init(hints: AppHints, snapshots: SnapshotBuilder) {
        self.hints = hints
        self.snapshots = snapshots
    }

    func endSession() {
        draft = nil
        undoStack.removeAll()
    }

    var draftForRouter: RouterInput.Draft? {
        draft.map { RouterInput.Draft(app: $0.appName, target: $0.targetDescription, typedText: $0.typedText) }
    }

    /// Execute one action tool. Control tools (wait, ignore, say, end, confirm, cancel)
    /// are handled by the session controller.
    func execute(_ call: ToolCall) async -> ExecOutcome {
        let snap = snapshots.snapshot
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
        case .scroll(let direction, let amount):
            KeyPresser.scroll(down: direction == .down, page: amount == .page, at: AppWindowAdapter.frontWindowCenter())
            outcome = .ok("Scrolled \(direction.rawValue)", undo: nil)
        case .undoLast:
            outcome = await undoLast()
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
                guard let pid = AppWindowAdapter.frontmostPID(), let el = try TextInputResolver.focusedEditable(in: pid) else {
                    return .fail("No text field is focused")
                }
                let app = NSRunningApplication(processIdentifier: pid)
                let t = TextInputResolver.Target(pid: pid, element: el, appName: app?.localizedName ?? "?", bundleID: app?.bundleIdentifier)
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
            } catch {
                return .fail("\(error)")
            }
        }
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
        case .element: ok = KeyPresser.press(d.hint?.submitKey ?? "return")
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
        }
    }
}
