import AppKit
import VoiceCommandCore

/// The one dictation engine (spec §5.5) behind every way of dictating: hold Fn, a spoken start
/// ("type…", "dictate into Claude Code…"), plain speech into a focused box, and the router's
/// `dictate`. A run is pinned to one place when it starts, types live or on a pause as
/// `TypingMode` says, mends mid-sentence pauses, and pauses when focus moves away.
///
/// Words are never consumed without a disposition: each piece handed in is disposed as typed
/// when it lands, or kept with the reason when it can't (moved away, no text box, a failure).
/// All typing goes through one serial queue, so steps never interleave.
@MainActor
final class DictationController {
    struct Run {
        var model: DictationRun
        let place: Executor.Place
    }

    /// What happened to words handed to the engine, for the record and the HUD.
    struct Report {
        var ok: Bool
        var message: String
        var typedAny = false
    }

    enum EndReason: String { case done, send, silence, command, movedAway = "moved_away", sessionEnd = "session_end" }

    private(set) var run: Run?
    /// The run that ended last, so "that was a command" and "scratch that" work just after it.
    private var lastRun: (run: Run, endedAt: Date)?
    private static let recentRunWindow: TimeInterval = 60

    private let executor: Executor
    private let hud: HUDPanel
    private let settings = AppSettings.shared
    /// Segments leave the session's buffer with a disposition (the buffer is the session's).
    var onDispose: ([Int], Disposition) -> Void = { _, _ in }
    /// Words that aren't in the buffer (a kept item typed again) go straight to the history.
    var onLoose: (String, Disposition, String?) -> Void = { _, _, _ in }

    private var tail: Task<Void, Never>?
    private var pasteQueued = false
    private var endQueued = false

    init(executor: Executor, hud: HUDPanel) {
        self.executor = executor
        self.hud = hud
    }

    // MARK: State for the intent gate

    var isRunning: Bool { run != nil }
    var hasWaiting: Bool { !(run?.model.waiting.isEmpty ?? true) }

    /// The current run, or one that ended under a minute ago, typed something.
    var typedRecently: Bool {
        if let r = run, !r.model.typed.isEmpty { return true }
        guard let l = lastRun, !l.run.model.typed.isEmpty else { return false }
        return Date().timeIntervalSince(l.endedAt) < Self.recentRunWindow
    }

    /// An action ran since: "scratch that" no longer means the old run.
    func forgetLastRun() { lastRun = nil }

    // MARK: Starting and feeding a run

    /// Start a run in the place `app` names, or where the keyboard focus is. `first` is typed
    /// as the mode says. If no place can be pinned, `first` is kept and nothing starts.
    func start(_ start: Decision.Start, source: TypingMode.Source, app: String?, snap: DesktopSnapshot,
               mediaPlaying: Bool, first: DictationRun.Piece?) async -> Report {
        var report = Report(ok: false, message: "")
        await serial { [self] in
            if run != nil { await finishNow(.command) }
            switch await executor.pinPlace(app: app, snap: snap) {
            case .failure(let f):
                if let first { keep([first], as: .kept(.nowhereToType), app: snap.frontmostApp?.name) }
                report.message = f.message + (first == nil ? "" : " — your words are kept: click a text box and say “type it”")
            case .success(let place):
                let surface = Self.surface(of: place, snap: snap)
                let mode = TypingMode.choose(surface: surface, source: source, mediaPlaying: mediaPlaying)
                run = Run(model: DictationRun(start: start, mode: mode, target: place.appName,
                                              leadingSpace: executor.needsLeadingSpace(place)), place: place)
                hud.model.badge = "Dictating into \(place.appName) — “send it” to send"
                report = Report(ok: true, message: "Dictating into \(place.appName)")
                if let first {
                    run!.model.add(first)
                    if mode == .live { report = await typeWaiting() }
                    else { report.message = "Dictating into \(place.appName) — typing when you pause" }
                }
            }
        }
        return report
    }

    /// More words for the run going: typed now when live, otherwise on the next pause.
    func add(_ piece: DictationRun.Piece, at: Date = Date()) async -> Report {
        guard run != nil else {
            keep([piece], as: .kept(.unclear), app: nil)
            return Report(ok: false, message: "No dictation going — your words are kept")
        }
        run!.model.add(piece, at: at)
        guard run!.model.mode == .live else { return Report(ok: true, message: "waiting for a pause") }
        var report = Report(ok: true, message: "")
        await serial { [self] in report = await typeWaiting() }
        return report
    }

    /// Speech started: not a pause yet.
    func heard() { run?.model.heard() }

    /// Every half second: paste on a pause, end a run on silence.
    func tick(now: Date, speaking: Bool) {
        guard let r = run else { return }
        if r.model.pasteDue(now: now, speaking: speaking), !pasteQueued {
            pasteQueued = true
            enqueue { [self] in _ = await typeWaiting(); pasteQueued = false }
        }
        if r.model.silenceEnds(now: now, speaking: speaking), !endQueued {
            endQueued = true
            enqueue { [self] in await finishNow(.silence); endQueued = false }
        }
    }

    // MARK: Ending

    /// End the run: type what's waiting, then stop. Typed text stays, unsent (I3).
    @discardableResult
    func finish(_ reason: EndReason) async -> Report {
        var report = Report(ok: true, message: "")
        await serial { [self] in report = await finishNow(reason) }
        return report
    }

    /// The session ended with no chance to type (mic changed, sleep): whatever is still
    /// waiting stays in the buffer, which keeps it (`kept(session_ended)`); loose words are
    /// kept here.
    func sessionEnded() {
        tail?.cancel()
        tail = nil
        if var r = run {
            let loose = r.model.takeWaiting().filter { $0.ids.isEmpty }
            keep(loose, as: .kept(.sessionEnded), app: r.place.appName)
        }
        run = nil
        lastRun = nil
        pasteQueued = false; endQueued = false
        hud.model.badge = nil
    }

    /// "Cancel dictation" / a quick "never mind": remove what the run typed (discarded, still
    /// in the history). A later "never mind" (`erase: false`) stops the run and keeps what was
    /// waiting (`kept(never_mind)`); what's already typed stays.
    func cancel(erase: Bool) async -> Report {
        var report = Report(ok: true, message: "")
        await serial { [self] in
            guard var r = run else { report = Report(ok: false, message: "No dictation to cancel"); return }
            let waiting = r.model.takeWaiting()
            run = nil
            hud.model.badge = nil
            if erase {
                keep(waiting, as: .discarded, app: r.place.appName)
                let removed = r.model.removeAll()
                if removed.chars > 0 {
                    _ = await executor.eraseDictation(removed.chars, in: r.place)
                    onLoose(removed.spoken, .discarded, r.place.appName)
                }
                report.message = "Dictation cancelled"
            } else {
                keep(waiting, as: .kept(.neverMind), app: r.place.appName)
                lastRun = (r, Date())
                report.message = waiting.isEmpty ? "Stopped dictating" : "Stopped dictating — your last words are kept"
            }
        }
        return report
    }

    // MARK: Recovery (spec §5.6)

    /// "That was a command": remove everything the current or last run typed, and return the
    /// words as said, to route as a command. Nil when there's nothing to take back.
    func takeBackForCommand() async -> String? {
        var spoken: String?
        await serial { [self] in
            guard var r = run ?? recentRun() else { return }
            let waiting = r.model.takeWaiting()
            let removed = r.model.removeAll()
            let words = Dictation.join([removed.spoken] + waiting.map(\.text)).trimmingCharacters(in: .whitespaces)
            // The waiting words are routed with the rest: in the buffer they're acted on now.
            onDispose(waiting.flatMap(\.ids), .acted)
            if removed.chars > 0 {
                guard case .typed = await executor.eraseDictation(removed.chars, in: r.place) else {
                    hud.model.show(.failure("Couldn't remove what I typed in \(r.place.appName)"), for: 3)
                    return
                }
            }
            run = nil; lastRun = nil
            hud.model.badge = nil
            spoken = words.isEmpty ? nil : words
        }
        return spoken
    }

    /// "Scratch that": remove the last chunk the current or last run typed.
    func scratch() async -> Report {
        var report = Report(ok: false, message: "Nothing to scratch")
        await serial { [self] in
            let inRun = run != nil
            guard var r = run ?? recentRun(), let chunk = r.model.removeLastChunk() else { return }
            guard case .typed = await executor.eraseDictation(chunk.text.count, restoring: chunk.replaced, in: r.place) else {
                report.message = "Couldn't remove it — \(r.place.appName) isn't in front"
                return
            }
            onLoose(chunk.spoken, .discarded, r.place.appName)
            if inRun { run = r } else { lastRun = (r, lastRun?.endedAt ?? Date()) }
            report = Report(ok: true, message: "Removed “\(DesktopSnapshot.clip(chunk.spoken, 40))”")
        }
        return report
    }

    /// Type words that aren't in the buffer (a kept item, the words of an undone action) once,
    /// into the focused box. Loose words go to the history as typed or kept.
    func typeOnce(_ text: String, snap: DesktopSnapshot) async -> Report {
        await finish(.command)
        var report = await start(.spoken, source: .local, app: nil, snap: snap, mediaPlaying: false, first: nil)
        guard report.ok else {
            onLoose(text, .kept(.nowhereToType), snap.frontmostApp?.name)
            return report
        }
        let added = await add(DictationRun.Piece(text: text))
        let flushed = await finish(.done)
        return flushed.message.isEmpty ? added : flushed
    }

    // MARK: Hold Fn

    /// Fn released: type everything said, once, into whatever has focus. Words that may not
    /// have landed are kept, not left on the clipboard (spec §1, loss path 9).
    func typeHeld(_ pieces: [DictationRun.Piece]) async -> Report {
        let texts = pieces.map(\.text)
        let text = settings.cleanUpDictation ? Dictation.clean(texts) : Dictation.join(texts)
        let ids = pieces.flatMap(\.ids)
        guard !text.isEmpty else {
            onDispose(ids, .kept(.noise))
            return Report(ok: false, message: "Didn't hear anything")
        }
        switch await executor.pasteHeld(text) {
        case .typed(let app):
            onDispose(ids, .typed)
            return Report(ok: true, message: "Typed into \(app)", typedAny: true)
        case .unsure(let app):
            onDispose(ids, .kept(.nowhereToType))
            return Report(ok: true, message: "Pasted into \(app), but I couldn't see a text box — if it didn't land, it's in the menu bar's Kept list")
        case .secure:
            onDispose(ids, .kept(.nowhereToType))
            return Report(ok: false, message: "That's a password field — not typed. Your words are in the menu bar's Kept list")
        }
    }

    // MARK: Private

    private func recentRun() -> Run? {
        guard let l = lastRun, Date().timeIntervalSince(l.endedAt) < Self.recentRunWindow else { return nil }
        return l.run
    }

    /// Run `op` after everything queued before it.
    @discardableResult
    private func enqueue(_ op: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let t = Task { @MainActor in
            await previous?.value
            await op()
        }
        tail = t
        return t
    }

    private func serial(_ op: @escaping @MainActor () async -> Void) async {
        await enqueue(op).value
    }

    /// Type everything waiting in one mended step. Call only from the queue.
    private func typeWaiting() async -> Report {
        guard let r = run, let (mend, pieces) = r.model.nextStep(cleanUp: settings.cleanUpDictation) else {
            return Report(ok: true, message: "")
        }
        let ids = pieces.flatMap(\.ids)
        if mend.text.isEmpty && mend.backspaces == 0 {
            // Only filler words ("um"): nothing to type.
            run?.model.didNotType(pieces)
            onDispose(ids, .kept(.noise))
            return Report(ok: true, message: "")
        }
        switch await executor.typeDictation(mend.text, backspaces: mend.backspaces, into: r.place) {
        case .typed:
            run?.model.didType(mend, pieces: pieces)
            onDispose(ids, .typed)
            for p in pieces where p.ids.isEmpty { onLoose(p.text, .typed, r.place.appName) }
            return Report(ok: true, message: "Typed into \(r.place.appName)", typedAny: true)
        case .movedAway:
            // Focus moved: the run pauses, and these words wait in Kept for "type it" (spec §5.5).
            run?.model.didNotType(pieces)
            keep(pieces, as: .kept(.movedAway), app: r.place.appName)
            endRun()
            let msg = "You moved away from \(r.place.appName) — your words are kept: say “type it” to put them here"
            hud.model.show(.info(msg), for: 3.5)
            return Report(ok: false, message: msg)
        case .failed(let why):
            // Typing failed (field gone, not editable): kept with the reason, never consumed.
            run?.model.didNotType(pieces)
            keep(pieces, as: .kept(.nowhereToType), app: r.place.appName)
            endRun()
            let msg = "\(why) — your words are kept: click a text box and say “type it”"
            hud.model.show(.failure(msg), for: 3.5)
            return Report(ok: false, message: msg)
        }
    }

    /// Type what's waiting, then end. Call only from the queue.
    @discardableResult
    private func finishNow(_ reason: EndReason) async -> Report {
        guard run != nil else { return Report(ok: true, message: "") }
        let report = await typeWaiting()
        // A failed step already ended the run and kept its words.
        if let r = run {
            // Implicit runs end quietly: the text is already typed.
            if reason == .silence, r.model.start != .implicit, !r.model.typed.isEmpty {
                hud.model.show(.info("Finished dictating into \(r.place.appName) — say “send” to send"), for: 2)
            }
            endRun()
        }
        return report
    }

    private func endRun() {
        if let r = run { lastRun = (r, Date()) }
        run = nil
        hud.model.badge = nil
    }

    private func keep(_ pieces: [DictationRun.Piece], as disposition: Disposition, app: String?) {
        let ids = pieces.flatMap(\.ids)
        if !ids.isEmpty { onDispose(ids, disposition) }
        for p in pieces where p.ids.isEmpty { onLoose(p.text, disposition, app) }
    }

    /// The kind of place, for the typing mode.
    static func surface(of place: Executor.Place, snap: DesktopSnapshot) -> TypingMode.Surface {
        switch place.target {
        case .terminal(let s):
            return TypingMode.surface(app: TerminalAdapter.appName(s.app), terminalProgram: s.running)
        case .element(let t):
            let url = TypingMode.isBrowser(t.bundleID) ? snap.activeTab?.url : nil
            return TypingMode.surface(app: t.appName, bundleID: t.bundleID, url: url)
        case .blind(let pid):
            let app = NSRunningApplication(processIdentifier: pid)
            let url = TypingMode.isBrowser(app?.bundleIdentifier) ? snap.activeTab?.url : nil
            return TypingMode.surface(app: place.appName, bundleID: app?.bundleIdentifier, url: url)
        }
    }
}
