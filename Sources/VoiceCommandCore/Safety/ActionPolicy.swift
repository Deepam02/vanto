import Foundation

/// Safety tiers (Final review point 7): either an action runs now, or it needs a spoken
/// yes/send. Everything here is pure so it can be unit-tested and replayed by router-eval.
public enum Tier: String, Codable, Sendable {
    case runsNow
    case needsApproval
}

public enum PolicyDecision: Equatable, Sendable {
    /// Run this (possibly rewritten) call. `minPauseMs` is the silence required before it
    /// may run (non-free actions wait for ~600 ms of pause and a current generation ID).
    case run(ToolCall, minPauseMs: Int, note: String?)
    /// Hold as a pending action until the person approves it.
    case hold(ToolCall, prompt: String)
    /// Refuse, with one HUD line.
    case reject(String)
    /// Leave this call out quietly: it repeats an earlier call in the same reply.
    case skip(String)

    public var isReject: Bool { if case .reject = self { return true }; return false }
}

public struct PolicyContext: Sendable {
    /// Latest utterance (text after the consumed cursor).
    public var transcript: String
    public var snapshot: DesktopSnapshot
    public var draftOpen: Bool
    public var draftText: String
    public var hasPending: Bool
    public var pendingSummary: String?

    public init(transcript: String, snapshot: DesktopSnapshot, draftOpen: Bool = false, draftText: String = "",
                hasPending: Bool = false, pendingSummary: String? = nil) {
        self.transcript = transcript; self.snapshot = snapshot; self.draftOpen = draftOpen
        self.draftText = draftText; self.hasPending = hasPending; self.pendingSummary = pendingSummary
    }
}

public enum ActionPolicy {
    public static let holdPauseMs = 600

    public static let approvalPhrases = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "confirm", "confirmed", "approve", "approved",
        "go ahead", "do it", "run it", "proceed", "affirmative", "go for it",
    ]

    /// Static tier of a tool, before any per-call checks.
    public static func tier(of call: ToolCall) -> Tier {
        switch call {
        case .submit: return .needsApproval
        case .terminalRun(_, let command, let source, let risk):
            return (source == .verbatim && risk == .read_only && !CommandRiskChecker.isRisky(command)) ? .runsNow : .needsApproval
        default: return .runsNow
        }
    }

    /// Evaluate the calls of one router reply, in order. Later calls see the effect of
    /// earlier ones (a type_text earlier in the reply opens a draft for a later submit).
    public static func evaluate(_ calls: [ToolCall], context: PolicyContext) -> [PolicyDecision] {
        var seq = ReplyEvaluator(context: context)
        return calls.map { seq.next($0) }
    }

    /// Incremental form of `evaluate(_:context:)` for calls that arrive one by one while
    /// the router reply is still streaming.
    public struct ReplyEvaluator: Sendable {
        public private(set) var context: PolicyContext
        private var payloadEndWord: Int?   // where this reply's typed payload ends in the transcript
        private var composed = false       // this reply typed text the router wrote
        private var removedTyped = false   // this reply already took typed text back out

        public init(context: PolicyContext) { self.context = context }

        public mutating func next(_ call: ToolCall) -> PolicyDecision {
            // One removal per request: "go back" after typing ran clear_typed and then
            // undo_last, which undid the action before as well (9 Nov).
            if removedTyped, case .undoLast = call { return .skip("already removed what was typed") }
            // Text the router wrote is read before it is sent: never sent in the same reply.
            if composed, case .submit = call { return .reject("Read it first, then say “send”") }
            let d = ActionPolicy.evaluate(call, context: context, payloadEndWord: payloadEndWord)
            if case .run(let c, _, _) = d, case .typeText(_, _, _, let payload, let source) = c {
                context.draftOpen = true
                context.draftText += (context.draftText.isEmpty ? "" : " ") + payload
                if source == .composed { composed = true } else {
                    payloadEndWord = TextMatching.transcriptSpan(for: payload, in: context.transcript)?.wordEnd
                }
            }
            if case .run(.clearTyped, _, _) = d { removedTyped = true }
            if case .run(.confirmPending, _, _) = d { context.hasPending = false }
            return d
        }
    }

    public static func evaluate(_ call: ToolCall, context ctx: PolicyContext, payloadEndWord: Int? = nil) -> PolicyDecision {
        let snap = ctx.snapshot
        switch call {
        case .focusWindow(let id):
            return snap.window(id) == nil ? .reject("That window isn't open any more") : .run(call, minPauseMs: 0, note: nil)

        case .browserSwitchTab(let id):
            return snap.tab(id) == nil ? .reject("That tab isn't open any more") : .run(call, minPauseMs: 0, note: nil)

        case .browserCloseTab(let id):
            guard let tab = snap.tab(id) else { return .reject("That tab isn't open any more") }
            // Switching on a near match is fine; closing one needs a yes ("close Blue U", 4 Nov).
            let said = Set(TextMatching.words(ctx.transcript).map(\.norm))
            let named = Set(TextMatching.words(tab.title + " " + tab.url.replacingOccurrences(of: ".", with: " ")).map(\.norm))
            let skip: Set<String> = ["close", "the", "tab", "this", "that", "a", "my", "please", "can", "you", "com", "www", "https"]
            if tab.active || !said.subtracting(skip).isDisjoint(with: named) { return .run(call, minPauseMs: 0, note: nil) }
            return .hold(call, prompt: "Close “\(DesktopSnapshot.clip(tab.title, 40))”? Say \"yes\".")

        case .terminalFocus(let id):
            if snap.terminal(id) != nil { return .run(call, minPauseMs: 0, note: nil) }
            if let s = snap.terminal(inWindow: id) { return .run(.terminalFocus(sessionID: s.id), minPauseMs: 0, note: "window \(id) → \(s.id)") }
            return .reject("That terminal session isn't open")

        case .browserOpenURL(let url, _):
            guard let u = URL(string: url), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                return .reject("Only web links can be opened")
            }
            return .run(call, minPauseMs: 0, note: nil)

        case .typeText(let target, let app, var sessionID, let payload, let source):
            if source == .composed {
                // Written for them: only when they asked for writing, never into a terminal
                // (the text would be a command or a prompt they didn't say), and never sent
                // without a spoken send (submit is still gated).
                guard target != .terminal else { return .reject("I only type your own words into a terminal") }
                guard isComposeRequest(ctx.transcript) else { return .reject("Couldn't match the text to what you said — nothing typed") }
                if target == .focused, let f = snap.focused, f.secure { return .reject("That's a password field — not typing") }
                let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= 3000 else { return .reject("That's too long to type") }
                return .run(.typeText(target: target, app: app, sessionID: nil, payload: text, source: .composed), minPauseMs: 0, note: "composed")
            }
            if target == .terminal {
                if let sid = sessionID, snap.terminal(sid) == nil { sessionID = snap.terminal(inWindow: sid)?.id }
                if sessionID == nil { sessionID = defaultTerminal(snap)?.id }
                guard let sid = sessionID, snap.terminal(sid) != nil else { return .reject("No terminal session to type into") }
            }
            if target == .focused, let f = snap.focused, f.secure {
                return .reject("That's a password field — not typing")
            }
            guard let span = TextMatching.transcriptSpan(for: payload, in: ctx.transcript) else {
                return .reject("Couldn't match the text to what you said — nothing typed")
            }
            // Never type a trailing newline (auto-submits in Claude Code).
            let text = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let note = span.exact ? nil : "payload mismatch: router \"\(payload)\" → typed transcript span"
            return .run(.typeText(target: target, app: app, sessionID: sessionID, payload: text), minPauseMs: 0, note: note)

        case .submit(_, let phrase):
            guard ctx.draftOpen else { return .reject("Nothing typed to send") }
            let phraseWords = TextMatching.words(phrase)
            guard !phraseWords.isEmpty, phraseWords.count <= 8 else { return .reject("Didn't hear a clear send request") }
            guard let at = TextMatching.lastWordIndex(of: phrase, in: ctx.transcript) else {
                return .reject("Didn't hear you say send — draft left unsent")
            }
            // The send phrase must come after the typed payload, not inside it.
            if let end = payloadEndWord, at < end {
                return .reject("\"\(phrase)\" was part of the message — draft left unsent")
            }
            return .run(call, minPauseMs: holdPauseMs, note: nil)

        case .terminalRun(var sid, let command, let source, let risk):
            if snap.terminal(sid) == nil {
                // A window ID means the session showing in that window; anything else, the default shell.
                guard let d = snap.terminal(inWindow: sid) ?? defaultShell(snap) else { return .reject("No terminal session open") }
                sid = d.id
            }
            let fixed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            if fixed.isEmpty || fixed.contains("\n") { return .reject("Can't run that command") }
            // A placeholder means a detail is missing (4 Nov typed `<UNKNOWN>` into the terminal).
            if fixed.range(of: "<[A-Za-z_-]+>|\\{\\{|\\bUNKNOWN\\b", options: .regularExpression) != nil {
                return .reject("I need one more detail for that command — say it again with the name")
            }
            if CommandRiskChecker.isForbidden(fixed) { return .reject("sudo is never run by voice") }
            let rewritten = ToolCall.terminalRun(sessionID: sid, command: fixed, source: source, risk: risk)
            let dictated = source == .verbatim && SpokenSymbols.isDictated(fixed, in: ctx.transcript)
            let findings = CommandRiskChecker.findings(fixed)
            if dictated && risk == .read_only && findings.isEmpty {
                return .run(rewritten, minPauseMs: holdPauseMs, note: nil)
            }
            var why: [String] = []
            if !dictated { why.append(source == .composed ? "composed" : "not dictated word for word") }
            if risk != .read_only { why.append(risk.rawValue.replacingOccurrences(of: "_", with: " ")) }
            if !findings.isEmpty { why.append(findings.map(\.rule).joined(separator: ", ")) }
            return .hold(rewritten, prompt: "Run `\(fixed)`? (\(why.joined(separator: "; "))) Say \"yes, run it\".")

        case .confirmPending:
            guard ctx.hasPending else { return .reject("Nothing is waiting for approval") }
            guard TextMatching.contains(ctx.transcript, anyOf: approvalPhrases) else {
                return .reject("Didn't hear a clear yes — still waiting")
            }
            return .run(call, minPauseMs: holdPauseMs, note: nil)

        case .cancelPending:
            return ctx.hasPending ? .run(call, minPauseMs: 0, note: nil) : .reject("Nothing is waiting for approval")

        case .newline, .clearTyped:
            return ctx.draftOpen ? .run(call, minPauseMs: 0, note: nil) : .reject("No draft open")

        case .pressKeys(let keys):
            guard let combo = KeyCombo.parse(keys) else { return .reject("Unknown keys: \(keys)") }
            // Enter while a draft is open is a send: it needs the person to have said it.
            if combo.isPlainReturn && ctx.draftOpen &&
                !TextMatching.contains(ctx.transcript, anyOf: ["enter", "return", "press enter", "hit enter"]) {
                return .reject("Didn't hear you say enter — draft left unsent")
            }
            return .run(call, minPauseMs: combo.isPlainReturn ? holdPauseMs : 0, note: nil)

        case .clickElement(let name, _), .menuCommand(let name, _):
            // Pressing "Delete", "Send", "Pay"… by name is irreversible: ask first.
            if let word = riskyClickWords.first(where: { TextMatching.contains(name, anyOf: [$0]) }) {
                return .hold(call, prompt: "\(word.capitalized): press “\(name)”? Say \"yes\".")
            }
            return .run(call, minPauseMs: 0, note: nil)

        case .rewriteDraft:
            // The one place composed text is typed: it only replaces this app's own unsent draft.
            return ctx.draftOpen ? .run(call, minPauseMs: 0, note: nil) : .reject("No draft to edit")

        case .startDictation(let target, let app, var sessionID, let text):
            if target == .terminal {
                if let sid = sessionID, snap.terminal(sid) == nil { sessionID = snap.terminal(inWindow: sid)?.id }
                if sessionID == nil { sessionID = defaultTerminal(snap)?.id }
                guard let sid = sessionID, snap.terminal(sid) != nil else { return .reject("No terminal session to type into") }
            }
            if target == .focused, let f = snap.focused, f.secure {
                return .reject("That's a password field — not typing")
            }
            // Words already said are kept only if they really were said.
            let said = text.flatMap { TextMatching.transcriptSpan(for: $0, in: ctx.transcript)?.text }
            return .run(.startDictation(target: target, app: app, sessionID: sessionID, text: said), minPauseMs: 0, note: nil)

        default:
            return .run(call, minPauseMs: 0, note: nil)
        }
    }

    /// Asking for writing ("write a post announcing…", "draft a reply", "make a post about"),
    /// as opposed to dictating the words. Composed text is allowed only then.
    public static let composeRequests = [
        "write", "draft", "compose", "come up with", "make a post", "make a tweet", "create a post", "make the post",
        "post about", "tweet about", "reply to", "respond to", "rewrite", "announce", "announcing", "something nice",
        "something like", "in a nice way", "in a beautiful manner", "nicely",
    ]

    public static func isComposeRequest(_ transcript: String) -> Bool {
        TextMatching.contains(transcript, anyOf: composeRequests)
    }

    /// Words that make a click or menu command irreversible enough to need a spoken yes.
    public static let riskyClickWords = [
        "delete", "remove", "send", "submit", "pay", "buy", "purchase", "checkout", "merge", "publish",
        "deploy", "discard", "erase", "unsubscribe", "transfer", "sign out", "log out", "empty trash",
    ]

    /// The terminal session a terminal action should use when none was named:
    /// the selected session running claude, then any session running claude, then any selected one.
    public static func defaultTerminal(_ snap: DesktopSnapshot) -> DesktopSnapshot.TerminalSession? {
        snap.terminals.first { $0.selected && $0.running != nil }
            ?? snap.terminals.first { $0.running != nil }
            ?? snap.terminals.first { $0.selected }
            ?? snap.terminals.first
    }

    /// The session a shell command should run in: a selected plain shell, then any plain shell.
    public static func defaultShell(_ snap: DesktopSnapshot) -> DesktopSnapshot.TerminalSession? {
        snap.preferredShellID.flatMap { id in snap.terminals.first { $0.id == id && $0.running == nil } }
            ?? snap.terminals.first { $0.selected && $0.running == nil }
            ?? snap.terminals.first { $0.running == nil }
    }
}

/// A parsed key combination like "cmd+shift+k" or "enter".
public struct KeyCombo: Equatable, Sendable {
    public var command = false, shift = false, option = false, control = false
    public var key: String

    public init(command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false, key: String) {
        self.command = command; self.shift = shift; self.option = option; self.control = control; self.key = key
    }

    public static let namedKeys: Set<String> = [
        "return", "enter", "escape", "esc", "tab", "space", "delete", "backspace", "forwarddelete",
        "up", "down", "left", "right", "home", "end", "pageup", "pagedown",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
    ]

    public var isPlainReturn: Bool { (key == "return" || key == "enter") && !command && !option && !control }

    /// Spoken or written key names for punctuation keys ("cmd+minus" was rejected on 4 Nov).
    static let keyAliases: [String: String] = [
        "esc": "escape", "minus": "-", "hyphen": "-", "dash": "-", "equal": "=", "equals": "=",
        "comma": ",", "period": ".", "dot": ".", "slash": "/", "backslash": "\\", "semicolon": ";",
        "quote": "'", "apostrophe": "'", "backtick": "`", "grave": "`", "leftbracket": "[", "rightbracket": "]",
    ]

    public static func parse(_ text: String) -> KeyCombo? {
        let lowered = text.lowercased().replacingOccurrences(of: " ", with: "")
        // "+" separates when present ("cmd+-"), otherwise "-" does ("cmd-k"). An empty last
        // piece means the key is the separator itself ("-", "cmd--", "cmd++").
        let sep: Character = lowered.contains("+") ? "+" : "-"
        var parts = lowered.split(separator: sep, omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" {
            parts.removeLast()
            if parts.last == "" { parts.removeLast() }
            parts.append(String(sep))
        }
        guard var last = parts.last, !last.isEmpty else { return nil }
        var shiftForPlus = false
        if last == "plus" || last == "+" { last = "="; shiftForPlus = true }
        var combo = KeyCombo(key: keyAliases[last] ?? last)
        combo.shift = shiftForPlus
        for mod in parts.dropLast() {
            switch mod {
            case "cmd", "command", "⌘": combo.command = true
            case "shift", "⇧": combo.shift = true
            case "opt", "option", "alt", "⌥": combo.option = true
            case "ctrl", "control", "⌃": combo.control = true
            default: return nil
            }
        }
        guard namedKeys.contains(combo.key) || (combo.key.count == 1) else { return nil }
        return combo
    }
}
