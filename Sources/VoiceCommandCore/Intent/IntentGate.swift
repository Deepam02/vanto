import Foundation

/// Where dictation could land right now (spec §5.2).
public enum FocusKind: Equatable, Sendable {
    /// An editable text field (Slack's message box, a Mail body, Notes).
    case textField(app: String)
    /// A prompt to a coding or AI assistant: Claude Code or Codex in a terminal, Claude,
    /// ChatGPT, Cursor's chat. Prompts say "you" to the assistant, not to Vanto.
    case assistantPrompt(app: String)
    /// A plain shell. Never receives implicit dictation.
    case shell(session: String)
    /// A password field, or secure keyboard entry on. Never receives dictation.
    case secure
    case none

    /// Plain speech may be typed here without being asked.
    public var takesImplicitDictation: Bool {
        switch self {
        case .textField, .assistantPrompt: return true
        case .shell, .secure, .none: return false
        }
    }

    public var label: String {
        switch self {
        case .textField(let app): return "text field (\(app))"
        case .assistantPrompt(let app): return "assistant prompt (\(app))"
        case .shell(let s): return "shell (\(s))"
        case .secure: return "secure field"
        case .none: return "nothing focused"
        }
    }

    static let terminalApps: Set<String> = ["Terminal", "iTerm2", "Ghostty"]

    /// From the snapshot prefetched when speech started.
    public static func from(_ snap: DesktopSnapshot) -> FocusKind {
        if snap.secureInputOn || snap.focused?.secure == true { return .secure }
        let front = snap.frontmostApp
        if let front, terminalApps.contains(front.name) {
            let session = snap.terminals.first { $0.selected && $0.app.displayName == front.name }
                ?? snap.terminals.first { $0.selected }
            if let s = session, let running = s.running?.lowercased(), running == "claude" || running == "codex" {
                return .assistantPrompt(app: running == "claude" ? "Claude Code" : "Codex")
            }
            return .shell(session: session?.title ?? front.name)
        }
        guard let f = snap.focused, f.editable else { return .none }
        let url = TypingMode.isBrowser(front?.bundleID) ? snap.activeTab?.url : nil
        let surface = TypingMode.surface(app: f.app, bundleID: front?.bundleID, url: url)
        return surface == .assistant ? .assistantPrompt(app: f.app) : .textField(app: f.app)
    }
}

extension DesktopSnapshot.TerminalApp {
    var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm2: return "iTerm2"
        case .ghostty: return "Ghostty"
        }
    }
}

extension TypingMode {
    static let browserBundles: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.brave.Browser", "com.microsoft.edgemac", "com.operasoftware.Opera",
    ]
    public static func isBrowser(_ bundleID: String?) -> Bool { bundleID.map(browserBundles.contains) ?? false }
}

/// What the gate knows besides the words (spec §5.2).
public struct IntentContext: Equatable, Sendable {
    public var focus: FocusKind
    /// Hold Fn: dictation, never a command.
    public var holdFn: Bool
    /// A dictation run is going (spoken or implicit), and where it types.
    public var runActive: Bool
    public var runTarget: String?
    /// The run's text so far ends mid-sentence ("…we should"), so the next words continue it.
    public var runEndsMidSentence: Bool
    /// The run (or the last thing Vanto did) typed text: "that was a command" / "scratch that" apply.
    public var typedRecently: Bool
    /// The last thing Vanto did was an action: "type that instead" applies.
    public var actedRecently: Bool
    /// The speech history has kept words from the last few minutes: "type it" / "copy it" refer to them.
    public var hasKept: Bool
    /// The speech history has kept words of any age: "type the one about X" searches them.
    public var keptEver: Bool
    /// An executor draft is open (Vanto typed it and is waiting for edits or "send").
    public var draftOpen: Bool
    /// The Mac is playing audio: speech without a command cue is probably the video.
    public var mediaPlaying: Bool
    /// Seconds since the person last said something that went to Vanto as a command.
    public var sinceSpokeToVanto: TimeInterval?
    /// Vanto's last reply was a question: a short answer answers it.
    public var vantoJustAsked: Bool
    /// A run was going into this app, and focus just moved somewhere else (spec §5.5).
    public var movedAwayFrom: String?

    public init(focus: FocusKind = .none, holdFn: Bool = false, runActive: Bool = false, runTarget: String? = nil,
                runEndsMidSentence: Bool = false, typedRecently: Bool = false, actedRecently: Bool = false,
                hasKept: Bool = false, keptEver: Bool = false, draftOpen: Bool = false, mediaPlaying: Bool = false,
                sinceSpokeToVanto: TimeInterval? = nil, vantoJustAsked: Bool = false, movedAwayFrom: String? = nil) {
        self.focus = focus; self.holdFn = holdFn; self.runActive = runActive; self.runTarget = runTarget
        self.runEndsMidSentence = runEndsMidSentence; self.typedRecently = typedRecently
        self.actedRecently = actedRecently; self.hasKept = hasKept
        self.keptEver = keptEver || hasKept; self.draftOpen = draftOpen
        self.mediaPlaying = mediaPlaying; self.sinceSpokeToVanto = sinceSpokeToVanto; self.vantoJustAsked = vantoJustAsked
        self.movedAwayFrom = movedAwayFrom
    }
}

/// What to do with one utterance, and why (logged as the record's `intent`).
public struct Decision: Equatable, Sendable {
    public enum Start: String, Codable, Equatable, Sendable {
        case holdFn = "hold_fn"
        /// "type…", "dictate into Claude Code…"
        case spoken
        /// Plain speech into a focused field.
        case implicit
        /// More words for the run already going.
        case continuing
    }

    public enum Route: Equatable, Sendable {
        /// Type `text` (into `target` when named, else the run's target or the focused field).
        case dictate(text: String, target: String?, start: Start)
        /// A command for sure: to the router.
        case command(text: String)
        /// Not sure: the router decides (it can still choose to dictate or keep).
        case router
        /// Into the speech history, silently.
        case keep(KeptReason)
        /// Ends the run, after typing `content`.
        case endRun(content: String, end: Dictation.End)
        case recover(Dictation.Recovery)
    }

    /// Which rule of §5.3 decided.
    public enum Step: String, Codable, Equatable, Sendable {
        case forced, recovery, run, explicitStart = "explicit_start", local, router
    }

    public var route: Route
    public var step: Step
    public var reason: String

    public init(route: Route, step: Step, reason: String) {
        self.route = route; self.step = step; self.reason = reason
    }

    /// For `TypingMode`: dictation the device decided is typed live where that fits.
    public var source: TypingMode.Source {
        if case .dictate(_, _, .holdFn) = route { return .holdFn }
        return step == .router ? .router : .local
    }

    /// "local: certain dictation (assistant prompt (Claude Code), 31 words)".
    public var logLine: String { "\(step == .router ? "router" : "local"): \(reason)" }
}

/// The intent decision, in front of the router (spec §5.3): cheap, certain rules first, and
/// anything not certain goes to the router. A pure function, replayable on logged speech.
///
/// The hard rule, checked on the 3–4 and 9 Nov logs (IntentGateTests): no command is ever
/// certain dictation, and no dictation is ever a certain command.
public enum IntentGate {
    // MARK: Thresholds (from the logs, spec §7)

    /// A certain command is at most this long. The longest one-shot commands in the logs are
    /// 10–12 words ("Can you go to Recents and the onboarding sidebar integration?").
    public static let maxCommandWords = 12
    /// Certain dictation is at least this long. Below it, prose and commands overlap
    /// ("That's how we will grow it into a big…", 10 words) and the router decides.
    public static let minDictationWords = 14
    /// Inside a run, a segment this short that reads like a command goes to the router.
    public static let maxRunCommandWords = 6
    /// A short answer right after Vanto asked something answers Vanto.
    public static let maxAnswerWords = 6
    /// With media playing, speech within this long of a command can still be for Vanto.
    public static let mediaFollowUpWindow: TimeInterval = 10

    public static func decide(_ utterance: String, _ ctx: IntentContext) -> Decision {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = TextMatching.words(text).map(\.norm)
        guard !words.isEmpty else { return Decision(route: .keep(.noise), step: .local, reason: "no words") }

        // 1. Forced.
        if ctx.holdFn {
            return Decision(route: .dictate(text: text, target: nil, start: .holdFn), step: .forced, reason: "hold Fn")
        }
        if let rest = addressedToVanto(text) {
            return Decision(route: .command(text: rest), step: .forced, reason: "addressed to Vanto")
        }

        // Recovery phrases, whole segment only.
        if let r = Dictation.recovery(in: text), let fit = recoveryApplies(r, ctx, namesItem: Dictation.namesKeptItem(text)) {
            return Decision(route: .recover(r), step: .recovery, reason: fit)
        }

        // 2. A run is going: more words for it, unless it ends or is clearly a command.
        if ctx.runActive {
            let (content, end) = Dictation.endCommand(in: text)
            if let end {
                return Decision(route: .endRun(content: content, end: end), step: .run, reason: "end phrase (\(end))")
            }
            if words.count <= maxRunCommandWords, !ctx.runEndsMidSentence, startsWithCue(text) || hasAskMarker(words) {
                return Decision(route: .router, step: .router, reason: "run active, short and reads like a command")
            }
            return Decision(route: .dictate(text: text, target: ctx.runTarget, start: .continuing), step: .run,
                            reason: "continues the run (\(words.count) words)")
        }

        // The run's app lost focus mid-dictation: the next words start a new run only if a text
        // box is focused here; otherwise they're kept. Anything that reads like a command or a
        // start phrase goes through the usual rules.
        if let from = ctx.movedAwayFrom, !readsLikeCommand(text) {
            if ctx.focus.takesImplicitDictation {
                return Decision(route: .dictate(text: text, target: nil, start: .implicit), step: .run,
                                reason: "run moved from \(from) to \(ctx.focus.label)")
            }
            return Decision(route: .keep(.movedAway), step: .local, reason: "moved away from \(from), nothing to type into")
        }

        // 3. Explicit start, handled here so "enter dictation into Claude Code" just works.
        if var start = explicitStart(text) {
            if start.verb == "note that", case .assistantPrompt = ctx.focus { start.text = text }   // content, not a note
            return Decision(route: .dictate(text: start.text, target: start.target, start: .spoken), step: .explicitStart,
                            reason: "explicit start (\(start.verb))" + (start.target.map { " into \($0)" } ?? ""))
        }

        // 4. Local certainty, both ways.
        if ctx.vantoJustAsked && words.count <= maxAnswerWords {
            return Decision(route: .command(text: text), step: .local, reason: "short answer to Vanto's question")
        }
        let cue = startsWithCue(text) || hasAskMarker(words)
        if ctx.mediaPlaying && !cue && (ctx.sinceSpokeToVanto.map { $0 > mediaFollowUpWindow } ?? true) {
            return Decision(route: .keep(.noise), step: .local, reason: "media playing, no command cue")
        }
        if case .assistantPrompt = ctx.focus {
            // Prompts are imperative and say "can you" to the assistant: never a certain command.
        } else if isCertainCommand(text, words) {
            return Decision(route: .command(text: text), step: .local, reason: "certain command (\(words.count) words)")
        }
        if let why = certainDictation(text, words, ctx) {
            return Decision(route: .dictate(text: text, target: nil, start: .implicit), step: .local, reason: why)
        }

        // 5. Everything else.
        return Decision(route: .router, step: .router, reason: "not certain (\(words.count) words, \(ctx.focus.label))")
    }

    // MARK: Rules

    static func isCertainCommand(_ text: String, _ words: [String]) -> Bool {
        words.count <= maxCommandWords && (startsWithCue(text) || hasAskMarker(words)) && !readsLikeMessage(text, words)
    }

    /// Why this is certain dictation, or nil.
    static func certainDictation(_ text: String, _ words: [String], _ ctx: IntentContext) -> String? {
        guard ctx.focus.takesImplicitDictation, !ctx.draftOpen, !ctx.mediaPlaying, words.count >= minDictationWords else { return nil }
        guard !hasAskMarker(words), !hasVantoMarker(words), !mentionsScreen(words) else { return nil }
        guard !sentences(text).contains(where: { startsWithCue($0) }) else { return nil }
        guard isFirstPerson(words) || greetsSomeone(text) else { return nil }
        return "certain dictation (\(ctx.focus.label), \(words.count) words)"
    }

    /// Recovery phrases apply only when there's something to recover; otherwise they're
    /// ordinary words ("copy it" with nothing kept is a copy command). "The one about X" and
    /// "the last one" name a kept item, so they search kept words of any age (no expiry).
    static func recoveryApplies(_ r: Dictation.Recovery, _ ctx: IntentContext, namesItem: Bool = false) -> String? {
        switch r {
        case .wasCommand, .scratchThat:
            return ctx.runActive || ctx.typedRecently ? "recovery after typing" : nil
        case .typeInstead:
            return ctx.actedRecently || ctx.hasKept ? "recovery after an action" : nil
        case .typeKept(let about), .copyKept(let about):
            if ctx.hasKept { return "kept words" }
            return (about != nil || namesItem) && ctx.keptEver ? "older kept words" : nil
        case .listKept:
            return "kept words"
        }
    }

    // MARK: Cues

    /// Words before the real start of a clause ("okay so", "uh now").
    static let leadingFillers: Set<String> = [
        "uh", "um", "umm", "uhm", "er", "erm", "ah", "oh", "hmm", "okay", "ok", "so", "now", "yeah", "yes", "yep", "no", "nah",
        "also", "and", "then", "hey", "hi", "hello", "please", "just", "alright", "right", "well", "like", "sorry", "actually",
    ]

    /// How commands start (after leading fillers), from the logs.
    static let startCues: [[String]] = [
        "open", "switch", "click", "tap", "scroll", "zoom", "close", "quit", "run", "search", "google", "focus", "pause",
        "play", "resume", "press", "hit", "continue", "mute", "unmute", "increase", "decrease", "reduce", "lower", "raise",
        "turn", "volume", "show", "hide", "find", "select", "undo", "redo", "reopen", "refresh", "reload", "minimize",
        "maximize", "move", "navigate", "launch", "go", "back", "next", "previous", "stop", "submit", "send", "post", "type",
        "write", "draft", "dictate", "make", "edit", "rewrite", "delete", "remove", "clear", "copy", "paste", "save", "create",
        "new", "end", "shut", "cancel", "confirm", "approve", "describe", "read", "bring", "enter", "set", "put", "drag",
        "keep scrolling", "keep going", "take me", "lets go", "lets open", "lets switch", "tell me", "what can", "what all",
        "what are the", "what is open", "whats open", "which tab", "which window", "where is", "where am",
    ].map { $0.split(separator: " ").map(String.init) }

    /// Asking someone to do something: "can you", "could you", "can we".
    static let askMarkers: [[String]] = [
        "can you", "could you", "would you", "will you", "cant you", "can u", "couldnt you", "can we", "could we",
    ].map { $0.split(separator: " ").map(String.init) }

    /// Talking to Vanto about what it did or should do on screen (3–9 Nov logs).
    static let vantoMarkers: [[String]] = [
        "want you to", "need you to", "asked you", "told you", "tell you", "you had to", "you opened", "you closed",
        "you typed", "you wrote", "you just", "which you", "you see", "can see", "like i said", "not this one",
        "the other one", "go back", "why are you", "are you able", "you didnt", "you did not", "your drafting",
    ].map { $0.split(separator: " ").map(String.init) }

    /// Things on screen: a sentence about them is about driving the Mac.
    static let screenWords: Set<String> = [
        "tab", "tabs", "window", "windows", "button", "sidebar", "scroll", "scrolling", "click", "video", "screen",
        "terminal", "chrome", "browser", "textbox", "volume", "zoom",
    ]

    static let firstPerson: Set<String> = [
        "i", "im", "ive", "id", "ill", "me", "my", "mine", "myself", "we", "weve", "wed", "our", "ours", "us", "lets",
    ]
    static let greetings: Set<String> = ["hey", "hi", "hello", "dear", "yo", "morning"]
    static let signOffs: [[String]] = [
        "thanks", "thank you", "cheers", "regards", "let me know", "talk soon", "see you", "send me", "get back to me",
    ].map { $0.split(separator: " ").map(String.init) }

    static func stripLeading(_ words: [String]) -> ArraySlice<String> {
        var s = words[...]
        while let w = s.first, leadingFillers.contains(w) { s = s.dropFirst() }
        return s
    }

    static func hasPrefix(_ words: ArraySlice<String>, _ phrase: [String]) -> Bool {
        words.count >= phrase.count && Array(words.prefix(phrase.count)) == phrase
    }

    static func containsPhrase(_ words: [String], _ phrases: [[String]]) -> Bool {
        phrases.contains { p in
            guard words.count >= p.count else { return false }
            return (0...(words.count - p.count)).contains { Array(words[$0..<$0 + p.count]) == p }
        }
    }

    /// The first clause starts like a command, after leading fillers.
    static func startsWithCue(_ text: String) -> Bool {
        let w = stripLeading(TextMatching.words(text).map(\.norm))
        return startCues.contains { hasPrefix(w, $0) }
    }

    static func hasAskMarker(_ words: [String]) -> Bool { containsPhrase(words, askMarkers) }

    /// Starts like a command or asks for something ("scroll up", "can you…").
    public static func readsLikeCommand(_ text: String) -> Bool {
        startsWithCue(text) || hasAskMarker(TextMatching.words(text).map(\.norm))
    }
    static func hasVantoMarker(_ words: [String]) -> Bool { containsPhrase(words, vantoMarkers) }
    static func mentionsScreen(_ words: [String]) -> Bool { words.contains(where: screenWords.contains) }
    static func isFirstPerson(_ words: [String]) -> Bool { words.contains(where: firstPerson.contains) }

    static func sentences(_ text: String) -> [String] {
        text.split(whereSeparator: { ".!?;\n".contains($0) }).map(String.init).filter { !TextMatching.words($0).isEmpty }
    }

    /// "Hey Priya, …" / "Hi team, …": a greeting, then a name or a group.
    static func greetsSomeone(_ text: String) -> Bool {
        let w = TextMatching.words(text)
        guard w.count >= 2, greetings.contains(w[0].norm) else { return false }
        if ["everyone", "all", "guys", "team", "folks", "there"].contains(w[1].norm) { return true }
        // A name is capitalised and isn't the start of a request ("Hey, Can you…").
        let notNames: Set<String> = ["can", "could", "what", "so", "is", "are", "i", "how", "please", "just", "go", "open"]
        return text[w[1].range].first?.isUppercase == true && !notNames.contains(w[1].norm)
    }

    /// Words to a person, not to Vanto: a greeting with a name, or a sign-off.
    static func readsLikeMessage(_ text: String, _ words: [String]) -> Bool {
        greetsSomeone(text) || containsPhrase(words, signOffs)
    }

    // MARK: Forced command

    static let vantoNames: Set<String> = ["vanto", "vando", "banto", "wanto"]

    /// "Vanto, open Slack" / "hey Vanto open Slack" → "open Slack". Also an escape from a run.
    /// The name must be followed by a comma or come after "hey"/"okay", so a sentence about
    /// Vanto ("Vanto is a voice tool…") stays prose.
    public static func addressedToVanto(_ text: String) -> String? {
        let w = TextMatching.words(text)
        guard !w.isEmpty else { return nil }
        var i = 0
        let called = ["hey", "ok", "okay"].contains(w[0].norm)
        if called { i = 1 }
        guard i < w.count, vantoNames.contains(w[i].norm) else { return nil }
        let after = text[w[i].range.upperBound...]
        let punctuated = after.first.map { ",:!".contains($0) } ?? false
        guard called || punctuated else { return nil }
        let rest = after.drop { ",:.!? ".contains($0) }.trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    // MARK: Explicit start

    public struct ExplicitStart: Equatable, Sendable {
        /// The words to type first (may be empty: "enter dictation into Claude Code").
        public var text: String
        /// The app or place named ("Claude Code"), when one was.
        public var target: String?
        /// Which start phrase: "type", "dictate", "write", "take a note", "note that", "enter dictation".
        public var verb: String
    }

    static let objectNouns = "message|messages|note|reply|comment|prompt|post|tweet|email|text|paragraph"
    static let politePrefix = "^(?:(?:uh|um|okay|ok|so|now|please|hey|alright|and)[,.]?\\s+)*(?:(?:can|could|would) you\\s+|please\\s+|let'?s\\s+)?"

    /// "type / write / dictate / take a note / note that / enter dictation [into X] …" at the
    /// start (spec §5.3 step 3). "Write" counts only with "saying", a colon, "down" or "the
    /// following": "write a post about X" asks the router to compose, which stays with it.
    public static func explicitStart(_ text: String) -> ExplicitStart? {
        let ci: String.CompareOptions = [.regularExpression, .caseInsensitive]
        // "enter dictation", "start dictating into Claude Code", "dictation mode".
        let modePattern = politePrefix + "(?:enter|start|begin|go)(?:\\s+(?:into|in|to))?\\s+(?:dictation|dictating)(?:\\s+mode)?\\b[,.:]?\\s*"
        if let r = text.range(of: modePattern, options: ci) {
            let after = String(text[r.upperBound...]).replacingOccurrences(of: "^(?:into|in|to|for|on)\\s+", with: "", options: ci)
            let (target, rest) = splitTarget(after, wholeRestIsTarget: true)
            return ExplicitStart(text: rest, target: target, verb: "enter dictation")
        }
        let verbPattern = politePrefix + "(type|dictate|write down|write|jot down|take a note|take note|note that)\\b[,:]?\\s*"
        guard let r = text.range(of: verbPattern, options: ci) else { return nil }
        let head = String(text[r])
        let verb = ["type", "dictate", "write down", "write", "jot down", "take a note", "take note", "note that"]
            .first { head.range(of: "\\b\($0)\\b[,:]?\\s*$", options: ci) != nil } ?? "type"
        var rest = String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        let polite = head.range(of: "(can|could|would) you|please", options: ci) != nil

        // "Type the last one", "paste the one about the deck": a kept item, never words to type.
        if rest.range(of: "^the (?:last one|one about|bit about)\\b", options: ci) != nil { return nil }
        // A "saying" marker or a colon: everything after it is the text, verbatim.
        if let m = rest.range(of: "(\\bsaying\\b|\\bthat says\\b|\\bwhich says\\b|:)", options: ci) {
            let pre = String(rest[..<m.lowerBound])
            // "Type a message to Priya saying…" names a person, not a place: the router's, like
            // "type a message to Priya" without the marker.
            if pre.range(of: "\\b(?:\(objectNouns))\\s+to\\s+\\S", options: ci) != nil { return nil }
            var body = String(rest[m.upperBound...])
            body = body.replacingOccurrences(of: "^[\\s,.:?]*(?:(?:that|like)\\b[\\s,.:?]*)?", with: "", options: ci)
            return ExplicitStart(text: body.trimmingCharacters(in: .whitespaces), target: targetIn(pre), verb: verb)
        }
        switch verb {
        case "write":
            guard let d = rest.range(of: "^(?:this down|that down|down|the following)\\b[,:.]?\\s*", options: ci) else { return nil }
            return ExplicitStart(text: String(rest[d.upperBound...]), target: nil, verb: verb)
        case "take a note", "take note", "note that", "jot down", "write down":
            rest = rest.replacingOccurrences(of: "^(?:that|of|of that)\\b[,:]?\\s*", with: "", options: ci)
            return ExplicitStart(text: rest, target: nil, verb: verb)
        default:
            // type / dictate
            if polite { return nil }   // "can you dictate a message for him" is the router's
            if rest.range(of: "^(?:into|in|to|on)\\s+[A-Z]", options: .regularExpression) != nil
                || rest.range(of: "^into\\s+", options: ci) != nil {
                let (target, body) = splitTarget(rest.replacingOccurrences(of: "^(?:into|in|to|on)\\s+", with: "", options: ci),
                                                 wholeRestIsTarget: verb == "dictate")
                return ExplicitStart(text: body, target: target, verb: verb)
            }
            // "type a message" with nothing else starts an empty run; "type a message to Priya" is the router's.
            if let o = rest.range(of: "^(?:a|an|the)\\s+(?:\(objectNouns))\\b[.!]?\\s*", options: ci) {
                return rest[o.upperBound...].isEmpty ? ExplicitStart(text: "", target: nil, verb: verb) : nil
            }
            let bare = TextMatching.words(rest).map(\.norm)
            if bare.isEmpty { return verb == "dictate" ? ExplicitStart(text: "", target: nil, verb: verb) : nil }
            if bare.count == 1 && ["this", "that", "it"].contains(bare[0]) { return nil }
            return ExplicitStart(text: rest, target: nil, verb: verb)
        }
    }

    /// "Claude Code, we need…" → ("Claude Code", "we need…"). Without punctuation, the target is
    /// the capitalised words at the start (at most 3), or everything when `wholeRestIsTarget`.
    static func splitTarget(_ s: String, wholeRestIsTarget: Bool) -> (target: String?, rest: String) {
        let s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return (nil, "") }
        if let p = s.range(of: "[,:.;]|\\bsaying\\b", options: [.regularExpression, .caseInsensitive]) {
            let target = s[..<p.lowerBound].trimmingCharacters(in: .whitespaces)
            let rest = s[p.upperBound...].trimmingCharacters(in: .whitespaces)
            return (target.isEmpty ? nil : stripArticle(target), rest)
        }
        if wholeRestIsTarget { return (stripArticle(s), "") }
        let words = TextMatching.words(s)
        var end = s.startIndex
        for w in words.prefix(3) {
            guard s[w.range].first?.isUppercase == true else { break }
            end = w.range.upperBound
        }
        guard end > s.startIndex else { return (nil, s) }
        return (String(s[..<end]), s[end...].trimmingCharacters(in: .whitespaces))
    }

    static func stripArticle(_ s: String) -> String {
        s.replacingOccurrences(of: "^(?:the)\\s+", with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// The place named before a "saying" marker: "in Slack", "into the Claude Code terminal".
    static func targetIn(_ pre: String) -> String? {
        let cleaned = pre.replacingOccurrences(of: "\\b(?:a|an)\\s+(?:\(objectNouns))\\b", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\\bfor me\\b", with: " ", options: [.regularExpression, .caseInsensitive])
        guard let r = cleaned.range(of: "\\b(?:in|into|on|to)\\s+(?!a\\b|an\\b)(.+)$", options: [.regularExpression, .caseInsensitive]) else { return nil }
        var t = String(cleaned[r]).replacingOccurrences(of: "^(?:in|into|on|to)\\s+", with: "", options: [.regularExpression, .caseInsensitive])
        // "in  in chat" after removing the object: take the last place named.
        if let last = t.range(of: "\\b(?:in|into|on|to)\\s+(?!a\\b|an\\b)", options: [.regularExpression, .caseInsensitive, .backwards]) {
            t = String(t[last.upperBound...])
        }
        t = stripArticle(t.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters)))
        // "In the chat", "in the box": the focused box, not an app called "chat".
        return t.isEmpty || genericPlaces.contains(TextMatching.normalized(t)) ? nil : t
    }

    /// Words that name the focused box rather than an app.
    static let genericPlaces: Set<String> = [
        "chat", "the chat", "chat box", "box", "text box", "textbox", "field", "text field", "input", "here", "this",
        "it", "this box", "this field", "the box", "message box", "reply box", "thread", "conversation",
    ]
}
