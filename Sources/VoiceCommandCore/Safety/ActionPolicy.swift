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
        var ctx = context
        var payloadEndWord: Int? = nil   // where this reply's typed payload ends in the transcript
        var out: [PolicyDecision] = []
        for call in calls {
            let d = evaluate(call, context: ctx, payloadEndWord: payloadEndWord)
            out.append(d)
            if case .run(let c, _, _) = d, case .typeText(_, _, _, let payload) = c {
                ctx.draftOpen = true
                ctx.draftText += (ctx.draftText.isEmpty ? "" : " ") + payload
                payloadEndWord = TextMatching.transcriptSpan(for: payload, in: ctx.transcript)?.wordEnd
            }
        }
        return out
    }

    public static func evaluate(_ call: ToolCall, context ctx: PolicyContext, payloadEndWord: Int? = nil) -> PolicyDecision {
        let snap = ctx.snapshot
        switch call {
        case .focusWindow(let id):
            return snap.window(id) == nil ? .reject("That window isn't open any more") : .run(call, minPauseMs: 0, note: nil)

        case .browserSwitchTab(let id), .browserCloseTab(let id):
            return snap.tab(id) == nil ? .reject("That tab isn't open any more") : .run(call, minPauseMs: 0, note: nil)

        case .terminalFocus(let id):
            return snap.terminal(id) == nil ? .reject("That terminal session isn't open") : .run(call, minPauseMs: 0, note: nil)

        case .browserOpenURL(let url, _):
            guard let u = URL(string: url), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                return .reject("Only web links can be opened")
            }
            return .run(call, minPauseMs: 0, note: nil)

        case .typeText(let target, let app, var sessionID, let payload):
            if target == .terminal {
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
                guard let d = defaultShell(snap) else { return .reject("No terminal session open") }
                sid = d.id
            }
            let fixed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            if fixed.isEmpty || fixed.contains("\n") { return .reject("Can't run that command") }
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

        default:
            return .run(call, minPauseMs: 0, note: nil)
        }
    }

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
        snap.terminals.first { $0.selected && $0.running == nil }
            ?? snap.terminals.first { $0.running == nil }
    }
}

/// A parsed key combination like "cmd+shift+k" or "enter".
public struct KeyCombo: Equatable, Sendable {
    public var command = false, shift = false, option = false, control = false
    public var key: String

    public static let namedKeys: Set<String> = [
        "return", "enter", "escape", "esc", "tab", "space", "delete", "backspace", "forwarddelete",
        "up", "down", "left", "right", "home", "end", "pageup", "pagedown",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
    ]

    public var isPlainReturn: Bool { (key == "return" || key == "enter") && !command && !option && !control }

    public static func parse(_ text: String) -> KeyCombo? {
        let parts = text.lowercased().replacingOccurrences(of: " ", with: "")
            .split(whereSeparator: { $0 == "+" || $0 == "-" }).map(String.init)
        guard let last = parts.last else { return nil }
        var combo = KeyCombo(key: last == "esc" ? "escape" : last)
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
