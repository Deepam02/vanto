import AppKit
import VoiceCommandCore

/// Set once a router reply has started a tool call; read by that route's watchdog.
@MainActor
private final class RouteFlag {
    var on = false
}

/// The session state machine (build spec) as amended by "Final review":
/// Idle → Warming → Listening ⇄ Speaking → Routing → Executing / Pending, plus Muted and
/// Drafting. One fixed commit delay (~450 ms) replaces speculation; newer speech bumps
/// the generation ID, cancels in-flight routing, and stale results never run.
@MainActor
final class SessionController {
    enum State: String {
        case idle, warming, listening, speaking, routing, executing, pending, muted
    }

    private(set) var state: State = .idle { didSet { onStateChange?(state) } }
    var onStateChange: ((State) -> Void)?
    var isActive: Bool { state != .idle }

    private let speech: SpeechEngine
    private let snapshots: SnapshotBuilder
    private let executor: Executor
    private let client: ClaudeClient
    private let hud: HUDPanel
    private let log: CommandLog
    private let settings = AppSettings.shared

    // Session data
    private var sessionID = ""
    private var startedAt = Date()
    private var buffer = TranscriptBuffer()
    /// Every segment heard this session and the dispositions written for it (invariant I1).
    private var ledger = DispositionLedger()
    /// Where every disposed segment is written (never-lose-dictation §3).
    private let speechHistory: SpeechHistory
    /// The one dictation engine (spec §5.5): hold Fn, spoken starts, plain speech, router `dictate`.
    private let dictation: DictationController
    private var history = SessionHistory()
    private var partial = ""
    private var generation = 0
    private var lastActivity = Date()
    private var lastSpeechEnd: Date?
    /// When the latest stretch of speech began: a snapshot read after it is current enough.
    private var lastSpeechStart = Date.distantPast
    private var holdActive = false
    private var muted = false
    private var pending: (call: ToolCall, prompt: String, recordID: String)?
    private var lastActedRecordID: String?
    /// When the last command did something, and the undo depth it left (so "type that
    /// instead" undoes that action, never an older one).
    private var lastActedAt: Date?
    private var lastActedTranscript: String?
    private var lastActionUndoDepth: Int?
    /// When something last went to the router as a command (media rule, spec §5.7).
    private var lastSpokeToVantoAt: Date?
    /// The record of the last dictation, for "that was a command" corrections.
    private var lastDictationRecordID: String?
    private var routeTask: Task<Void, Never>?
    private var scheduledRoute: Task<Void, Never>?
    private var ticker: Timer?
    private var observers: [NSObjectProtocol] = []
    private var unloadTimer: Timer?
    // Hold-Fn dictation: a session that only types what was said, no routing.
    private var dictationOnly = false
    /// What was said while Fn is held, claimed from the buffer until release.
    private var held: [DictationRun.Piece] = []
    /// "That was a command" / "type that instead" refer to things done this recently.
    private static let recentWindow: TimeInterval = 60
    /// "Type it" refers to words kept this recently (the history itself has no expiry).
    private static let keptRecallWindow: TimeInterval = 600
    /// Echo cancellation was on for this session's mic (logged; it adds latency).
    private var echoCancel = false
    // Latency of the last speech segment, copied into the next command record.
    /// Speech just stopped a continuous scroll: that short utterance was the "stop" (often
    /// heard as "Store", 4 Nov) and must not be routed or pile up in the buffer.
    private var speechStoppedScroll = false
    /// Generations already retried after a timeout (one automatic retry each).
    private var timeoutRetried = Set<Int>()
    private var lastSegmentLagMs: Int?
    private var lastTranscribeMs: Int?

    init(speech: SpeechEngine, snapshots: SnapshotBuilder, executor: Executor, client: ClaudeClient, hud: HUDPanel, log: CommandLog,
         speechHistory: SpeechHistory) {
        self.speech = speech; self.snapshots = snapshots; self.executor = executor
        self.client = client; self.hud = hud; self.log = log; self.speechHistory = speechHistory
        dictation = DictationController(executor: executor, hud: hud)
        dictation.onDispose = { [weak self] ids, d in
            guard let self else { return }
            self.buffer.dispose(ids, as: d)
            self.recordDisposed()
        }
        dictation.onLoose = { [weak self] text, d, app in
            guard let self else { return }
            self.speechHistory.append(.init(text: text, disposition: d, sessionID: self.sessionID, app: app))
        }
        speech.onEvent = { [weak self] e in self?.handle(e) }
        speech.capture.onDeviceChange = { [weak self] in
            guard let self, self.isActive else { return }
            self.end(reason: "mic changed", message: "Microphone changed — session ended")
        }
    }

    // MARK: Start / stop

    func toggle() {
        if dictationOnly { return }   // releasing Fn ends dictation
        guard isActive else { start(); return }
        // Words waiting for a pause are typed before the session ends.
        if dictation.hasWaiting {
            Task { await dictation.finish(.sessionEnd); end(reason: "hotkey") }
        } else {
            end(reason: "hotkey")
        }
    }

    // MARK: Dictation (hold Fn)

    /// Hold Fn: listen and, on release, type everything said into the focused field.
    /// Local only (no API key, no router), so pauses and "um"s can't end or lose it.
    func startDictation() {
        guard state == .idle else { return }   // a command session already owns the mic
        unloadTimer?.invalidate()
        dictationOnly = true
        held = []
        sessionID = UUID().uuidString
        startedAt = Date()
        lastActivity = Date()
        buffer.reset(); recordDisposed(); ledger.reset(); partial = ""
        hud.model.liveText = ""; hud.model.pendingPrompt = nil; hud.model.draftPreview = nil; hud.model.flash = nil
        hud.setVisible(true)
        state = .warming
        hud.model.mode = .warming
        Task {
            if !speech.modelsLoaded {
                do {
                    try await speech.loadModels { [weak self] p in
                        MainActor.assumeIsolated { self?.hud.model.downloadProgress = p < 1 ? p : nil }
                    }
                    hud.model.downloadProgress = nil
                } catch {
                    hud.model.downloadProgress = nil
                    end(reason: "model load failed", message: "Speech models failed to load: \(error.localizedDescription)")
                    return
                }
            }
            // Released while the models were loading.
            guard dictationOnly, state == .warming else { return }
            await loadVocabulary(snapshots.snapshot)
            guard dictationOnly, state == .warming else { return }
            echoCancel = wantEchoCancel()
            do {
                try speech.startListening(useBuiltIn: settings.useBuiltInMic, cancelEcho: echoCancel)
            } catch {
                end(reason: "mic failed", message: "\(error)")
                return
            }
            state = .listening
            hud.model.mode = .dictating
        }
    }

    /// Fn released: let the last words finish transcribing, then type it all.
    func finishDictation() async {
        guard dictationOnly else { return }
        if state == .warming {
            dictationOnly = false
            state = .idle
            hud.model.show(.info("Speech is still loading — hold Fn again in a moment"), for: 2)
            hideHUDSoon(after: 2.1)
            return
        }
        state = .executing
        hud.model.mode = .thinking
        await speech.finishListening()
        let pieces = held
        dictationOnly = false
        held = []

        let report = await dictation.typeHeld(pieces)
        var record = CommandRecord(sessionID: sessionID, generation: 0, transcript: Dictation.join(pieces.map(\.text)))
        record.tools = ["dictation"]
        record.intent = "local: hold Fn"
        record.segments = pieces.flatMap(\.ids)
        record.decisions = ["dictate (hold Fn, on release) → \(report.message)"]
        record.results = [report.message]
        record.outcome = pieces.isEmpty ? "ignored" : (report.typedAny ? "ok" : (report.ok ? "kept" : "failed"))
        record.disposition = pieces.isEmpty ? nil : (report.typedAny ? "typed" : "kept:nowhere_to_type")
        record.actionDoneAt = Date().timeIntervalSince1970
        log.append(record)
        recordDisposed()
        var session = SessionRecord(sessionID: sessionID, startedAt: startedAt, endedAt: Date(), endReason: "dictation")
        session.echoCancel = echoCancel
        session.wordsLost = wordsLost()
        log.append(session)

        state = .idle
        hud.model.liveText = ""
        hud.model.mode = .listening
        hud.model.show(report.typedAny ? .success(report.message) : (report.ok ? .info(report.message) : .failure(report.message)),
                       for: report.typedAny ? 1.6 : 3.5)
        hideHUDSoon(after: report.typedAny ? 1.7 : 3.6)
        scheduleUnload()
    }

    private func hideHUDSoon(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.state == .idle else { return }
            self.hud.model.mode = .hidden
            self.hud.setVisible(false)
        }
    }

    /// Load on first use, unload after 10 idle minutes.
    private func scheduleUnload() {
        unloadTimer?.invalidate()
        unloadTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in
            Task { await self?.speech.unloadModels() }
        }
    }

    func start() {
        guard state == .idle else { return }
        guard let key = APIKeyStore.load() else {
            NotificationCenter.default.post(name: .openSettings, object: nil)
            hud.setVisible(true)
            hud.model.mode = .listening
            hud.model.show(.failure("Add your Anthropic API key in Settings"), for: 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
                if self?.state == .idle { self?.hud.setVisible(false); self?.hud.model.mode = .hidden }
            }
            return
        }
        client.apiKey = key
        client.workspaceID = settings.workspaceID
        unloadTimer?.invalidate()
        sessionID = UUID().uuidString
        startedAt = Date()
        lastActivity = Date()
        buffer.reset(); recordDisposed(); ledger.reset(); history.reset(); partial = ""; pending = nil; holdActive = false; muted = false
        lastActedAt = nil; lastActedTranscript = nil; lastActionUndoDepth = nil; lastSpokeToVantoAt = nil
        timeoutRetried.removeAll()
        snapshots.preferredShellID = nil
        hud.model.liveText = ""; hud.model.pendingPrompt = nil; hud.model.draftPreview = nil; hud.model.flash = nil
        hud.setVisible(true)
        snapshots.beginLive()
        Task { await client.warmUp() }

        if !speech.modelsLoaded {
            state = .warming
            hud.model.mode = .warming
            Task {
                do {
                    try await speech.loadModels { [weak self] p in
                        MainActor.assumeIsolated { self?.hud.model.downloadProgress = p < 1 ? p : nil }
                    }
                    hud.model.downloadProgress = nil
                    guard state == .warming else { return }
                    await beginListening()
                } catch {
                    hud.model.downloadProgress = nil
                    end(reason: "model load failed", message: "Speech models failed to load: \(error.localizedDescription)")
                }
            }
        } else {
            Task { await beginListening() }
        }
    }

    /// Words to listen for this session: the person's dictionary, then names on screen.
    private func loadVocabulary(_ snap: DesktopSnapshot) async {
        await speech.setVocabulary(extra: ScreenVocabulary.appTerms(snap.apps.map(\.name)) + ScreenVocabulary.terms(from: snap),
                                   personal: ScreenVocabulary.parseDictionary(settings.personalDictionary))
    }

    /// Echo cancellation adds latency (4 Nov: ~0.9 s more before routing), so it's on only
    /// when the Mac is playing something it could hear.
    private func wantEchoCancel() -> Bool { settings.cancelMacAudio && AudioCapture.outputIsPlaying() }

    private func beginListening() async {
        let snap = await snapshots.refresh()
        await loadVocabulary(snap)
        guard state == .warming || state == .idle else { return }
        echoCancel = wantEchoCancel()
        do {
            try speech.startListening(useBuiltIn: settings.useBuiltInMic, cancelEcho: echoCancel)
        } catch {
            end(reason: "mic failed", message: "\(error)")
            return
        }
        state = .listening
        hud.model.mode = .listening
        hud.model.warning = snap.secureInputOn ? "Secure keyboard entry is on in some app — typing may not work" : nil
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        installSystemObservers()
    }

    func end(reason: String, message: String? = nil) {
        guard state != .idle else { return }
        generation += 1
        routeTask?.cancel(); scheduledRoute?.cancel()
        routeTask = nil; scheduledRoute = nil
        speech.stopListening()
        ticker?.invalidate(); ticker = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
        var message = message
        if dictationOnly {
            // Cut short (mic changed, models failed): never lose what was said. The held words
            // are claimed in the buffer, which keeps them below (kept(session_ended)).
            dictationOnly = false
            if !held.isEmpty { message = (message ?? "Dictation stopped") + " — your words are in the menu bar's Kept list" }
            held = []
        } else {
            snapshots.endLive()
        }

        // Final review 8: an open draft stays typed but unsent; a pending action is cancelled.
        var notes: [String] = []
        if executor.draft != nil { notes.append("draft left unsent") }
        if let p = pending {
            notes.append("pending action cancelled")
            log.append(CorrectionRecord(commandID: p.recordID, sessionID: sessionID, how: "cancel_pending"))
        }
        pending = nil
        // A run's typed text stays, unsent; words it hadn't typed yet are kept.
        if dictation.hasWaiting { notes.append("your last words are kept") }
        dictation.sessionEnded()
        buffer.reset()
        recordDisposed()
        executor.abandonPretyped()
        executor.endSession()
        var session = SessionRecord(sessionID: sessionID, startedAt: startedAt, endedAt: Date(), endReason: reason)
        session.echoCancel = echoCancel
        session.wordsLost = wordsLost()
        log.append(session)

        state = .idle
        let text = message ?? (notes.isEmpty ? "Session ended" : "Session ended — " + notes.joined(separator: ", "))
        hud.model.pendingPrompt = nil
        hud.model.draftPreview = nil
        hud.model.mode = .listening
        hud.model.show(message == nil ? .info(text) : .failure(text), for: 1.6)
        hideHUDSoon(after: 1.7)
        scheduleUnload()
    }

    func setMuted(_ on: Bool) {
        guard isActive, state != .warming else { return }
        muted = on
        if on {
            generation += 1
            routeTask?.cancel(); scheduledRoute?.cancel()
            state = .muted
            hud.model.mode = .muted
        } else {
            state = .listening
            hud.model.mode = executor.draft != nil ? .drafting : .listening
            lastActivity = Date()
        }
    }

    var isMuted: Bool { muted }

    private func installSystemObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.end(reason: "sleep or lock") }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.end(reason: "screen locked") }
        })
    }

    // MARK: Timers

    private func tick() {
        guard isActive, state != .warming else { return }
        let now = Date()
        if now.timeIntervalSince(startedAt) > Double(AppSettings.hardSessionCapSec) {
            end(reason: "10 minute cap", message: "Session ended after 10 minutes")
            return
        }
        if buffer.keepStale(now: now) { recordDisposed(); refreshLiveText() }
        dictation.tick(now: now, speaking: isSpeaking)
        // Idle time only; suspended while a draft is open, an action is pending, or after "hold on".
        let suspended = executor.draft != nil || pending != nil || holdActive || dictation.isRunning ||
            state == .routing || state == .executing || state == .speaking
        if !suspended && !muted && now.timeIntervalSince(lastActivity) > Double(settings.idleTimeoutSec) {
            end(reason: "idle")
        }
    }

    /// Between the start of speech and the segment it becomes.
    private var isSpeaking: Bool { lastSpeechStart > (lastSpeechEnd ?? .distantPast) }

    // MARK: Speech events

    private func handle(_ e: SpeechEngine.Event) {
        guard isActive, state != .warming else { return }
        if dictationOnly { handleDictation(e); return }
        switch e {
        case .speechStarted:
            lastActivity = Date()
            lastSpeechStart = Date()
            snapshots.prefetch()
            hud.model.hideCard()
            if executor.isScrolling {
                executor.stopScrolling()
                speechStoppedScroll = true
            }
            holdActive = false
            // New speech: anything in flight is stale (generation ID), and nothing scheduled fires.
            generation += 1
            scheduledRoute?.cancel()
            if state == .routing { routeTask?.cancel() }
            if !muted && state != .executing && state != .pending { state = .speaking }
            if !muted { hud.model.mode = dictation.isRunning ? .dictating : .speaking }
            dictation.heard()

        case .partial(let text):
            partial = text
            refreshLiveText()

        case .segment(let text, let live, let raw, _, let endedAt, let transcribeMs):
            lastActivity = Date()
            partial = ""
            lastSpeechEnd = endedAt
            lastSegmentLagMs = Int(Date().timeIntervalSince(endedAt) * 1000)
            lastTranscribeMs = transcribeMs
            if speechStoppedScroll {
                speechStoppedScroll = false
                let said = text.isEmpty ? live : text
                let w = TextMatching.words(said).map(\.norm)
                // Short speech was the "stop" (often heard as "Store"): acted on, and in the history
                // like any other. A short real command ("scroll up") is decided as usual (loss path 7).
                if w.count <= 4 && (w.contains("stop") || !IntentGate.readsLikeCommand(said)) {
                    buffer.dispose([hear(said, endedAt: endedAt)], as: .acted)
                    recordDisposed()
                    if state == .speaking { state = pending != nil ? .pending : .listening }
                    hud.model.mode = modeForIdle()
                    hud.model.show(.info("Stopped scrolling"), for: 1.2)
                    return
                }
            }
            if muted {
                if TextMatching.contains(text, anyOf: ["resume", "resume listening", "start listening", "unpause"]) {
                    setMuted(false)
                    hud.model.show(.info("Listening again"), for: 1.2)
                }
                return
            }
            hear(text.isEmpty ? live : text, endedAt: endedAt, raw: text.isEmpty ? nil : raw)
            if buffer.keepStale() { recordDisposed() }
            refreshLiveText()
            if state == .speaking { state = pending != nil ? .pending : .listening }
            hud.model.mode = modeForIdle()
            scheduleRoute(after: endedAt)
        case .failure(let message):
            hud.model.show(.failure(message))
        }
    }

    /// While Fn is held every segment is kept, whatever the pauses: nothing is routed.
    private func handleDictation(_ e: SpeechEngine.Event) {
        switch e {
        case .speechStarted:
            lastActivity = Date()
        case .partial(let text):
            partial = text
        case .segment(let text, let live, let raw, _, let endedAt, _):
            lastActivity = Date()
            partial = ""
            let words = text.isEmpty ? live : text
            // In the buffer (and claimed), so a cut-short hold is kept, never lost.
            let id = hear(words, endedAt: endedAt, raw: text.isEmpty ? nil : raw)
            buffer.claim([id])
            if !words.trimmingCharacters(in: .whitespaces).isEmpty { held.append(.init(text: words, ids: [id])) }
        case .failure(let message):
            hud.model.show(.failure(message))
            return
        }
        hud.model.liveText = ([Dictation.join(held.map(\.text)), partial].filter { !$0.isEmpty }).joined(separator: " ")
    }

    private func refreshLiveText() {
        let pieces = [buffer.latest, partial].filter { !$0.isEmpty }
        hud.model.liveText = pieces.joined(separator: " ")
    }

    private func modeForIdle() -> HUDModel.Mode {
        if muted { return .muted }
        if dictation.isRunning { return .dictating }
        if pending != nil { return .pending }
        if executor.draft != nil { return .drafting }
        return .listening
    }

    // MARK: Routing

    // A phrase ending on one of these is unfinished ("…we need to add Linear, uh and like").
    // Not "on", "in", "that": "switch it on", "log in", "undo that" are whole commands.
    private static let trailingWaitWords: Set<String> = [
        "um", "uh", "er", "erm", "hmm", "and", "so", "then", "or", "but", "because",
        "like", "the", "a", "an", "to", "of", "for", "with", "my", "your", "our",
    ]
    private static let holdPhrases = ["hold on", "wait", "let me think", "one sec", "one second", "give me a sec"]
    private static let mutePhrases = ["pause listening", "stop listening for now", "mute yourself"]
    /// Past this many words it's probably dictation, not a command: give pauses longer.
    private static let longUtteranceWords = 20
    private static let longUtteranceExtraMs = 900
    /// Extra router turns after look_again, per request.
    private static let maxFollowUps = 2
    /// History note for actions that ran before newer speech cancelled the request.
    static let doneWhileTalking = "done while you were still talking"

    private func scheduleRoute(after speechEnd: Date) {
        scheduledRoute?.cancel()
        let gen = generation
        var commitMs = settings.commitDelayMs
        if TextMatching.words(buffer.latest).count > Self.longUtteranceWords { commitMs += Self.longUtteranceExtraMs }
        let delay = max(0, Double(commitMs) / 1000 - Date().timeIntervalSince(speechEnd))
        scheduledRoute = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self, !Task.isCancelled, self.generation == gen else { return }
            self.routeNow(generation: gen)
        }
    }

    private func routeNow(generation gen: Int) {
        let transcript = buffer.latest
        guard !transcript.isEmpty else { return }
        let words = TextMatching.words(transcript).map(\.norm)

        // "End the session" is local too, so leftover words before it can't stall it.
        if SessionPhrases.endsSession(transcript) {
            var record = CommandRecord(sessionID: sessionID, generation: gen, transcript: transcript)
            record.rawTranscript = buffer.latestRaw
            record.speechEndAt = lastSpeechEnd?.timeIntervalSince1970
            record.tools = ["end_session"]
            record.decisions = ["end_session (local)"]
            record.intent = "local: end the session"
            record.segments = buffer.latestSegmentIDs
            record.outcome = "ok"
            record.actionDoneAt = Date().timeIntervalSince1970
            // The last segment ended the session; anything before it ("Henderson.") is kept.
            let ids = buffer.latestSegmentIDs
            buffer.dispose(Array(ids.dropLast()), as: .kept(.unclear))
            buffer.disposeAll(as: .acted)
            recordDisposed()
            log.append(record)
            // A run's waiting words are typed first; its text stays, unsent.
            Task { await dictation.finish(.sessionEnd); end(reason: "spoken") }
            return
        }
        // Spoken mute is local: no round trip needed. Its words are acted on, and in the history.
        if TextMatching.contains(transcript, anyOf: Self.mutePhrases) && words.count <= 5 {
            buffer.disposeAll(as: .acted)
            recordDisposed()
            refreshLiveText()
            setMuted(true)
            return
        }

        let segmentIDs = buffer.latestSegmentIDs
        let raw = buffer.latestRaw
        routeTask?.cancel()
        routeTask = Task { [weak self] in
            await self?.decide(transcript: transcript, raw: raw, segmentIDs: segmentIDs, generation: gen)
        }
    }

    // MARK: The intent gate (spec §5.3)

    /// What the gate knows besides the words.
    private func intentContext(focus: FocusKind, mediaPlaying: Bool, movedAwayFrom: String?) -> IntentContext {
        let now = Date()
        let run = dictation.run
        return IntentContext(
            focus: focus, runActive: run != nil, runTarget: run?.place.appName,
            runEndsMidSentence: run?.model.endsMidSentence ?? false,
            typedRecently: dictation.typedRecently,
            actedRecently: lastActedAt.map { now.timeIntervalSince($0) < Self.recentWindow } ?? false,
            hasKept: speechHistory.lastKept.map { now.timeIntervalSince($0.date) < Self.keptRecallWindow } ?? false,
            draftOpen: executor.draft.map { !$0.byDictation } ?? false,
            mediaPlaying: mediaPlaying,
            sinceSpokeToVanto: lastSpokeToVantoAt.map { now.timeIntervalSince($0) },
            vantoJustAsked: history.lastQuestion != nil,
            movedAwayFrom: movedAwayFrom)
    }

    /// Every finished utterance goes through the gate: dictation, the router, or kept. Nothing
    /// leaves the buffer without a disposition.
    private func decide(transcript: String, raw: String?, segmentIDs: [Int], generation gen: Int) async {
        let snap = await snapshots.current(since: lastSpeechStart)
        guard generation == gen, !Task.isCancelled else { return }
        let media = AudioCapture.outputIsPlaying()
        let focus = FocusKind.from(snap)

        // The run's place isn't in front any more: the run pauses (spec §5.5). Its waiting words
        // can't be typed there, so they're kept (moved away).
        var movedFrom: String?
        if let r = dictation.run, let here = executor.placeKey(snap), here != r.place.key {
            movedFrom = r.place.appName
            await dictation.finish(.movedAway)
            guard generation == gen, !Task.isCancelled else { return }
        }

        var decision = IntentGate.decide(transcript, intentContext(focus: focus, mediaPlaying: media, movedAwayFrom: movedFrom))
        if !settings.implicitDictation, case .dictate(_, _, .implicit) = decision.route {
            // Settings: typing unasked is off. The router decides, as before (spec §8).
            decision = Decision(route: .router, step: .router, reason: decision.reason + "; typing unasked is off")
        }
        var record = CommandRecord(sessionID: sessionID, generation: gen, transcript: transcript)
        record.rawTranscript = raw
        record.speechEndAt = lastSpeechEnd?.timeIntervalSince1970
        record.transcriptFinalAt = Date().timeIntervalSince1970
        record.segmentLagMs = lastSegmentLagMs
        record.transcribeMs = lastTranscribeMs
        record.intent = decision.logLine
        record.focusKind = focus.label
        record.mediaPlaying = media
        record.segments = segmentIDs

        switch decision.route {
        case .router, .command:
            let words = TextMatching.words(transcript).map(\.norm)
            // Thinking pauses: trailing filler/connectors always wait, without a router call.
            if settings.thinkingPauses, !dictation.isRunning, let last = words.last, Self.trailingWaitWords.contains(last) {
                hud.model.mode = modeForIdle()
                return
            }
            if Self.holdPhrases.contains(where: { TextMatching.normalized(transcript).hasSuffix($0) }) { holdActive = true }
            // A command ends the run: its typed text stays, unsent (spec §5.5).
            let runTarget = dictation.run?.place.appName
            if runTarget != nil {
                await dictation.finish(.command)
                guard generation == gen, !Task.isCancelled else { return }
            }
            var text = transcript
            if case .command(let t) = decision.route { text = t }
            await route(transcript: text, raw: raw, segmentIDs: segmentIDs, generation: gen, intent: decision,
                        focus: focus, mediaPlaying: media, dictationRun: runTarget)

        case .dictate(let text, let target, let start):
            await dictateLocally(text: text, target: target, start: start, decision: decision, segmentIDs: segmentIDs,
                                 snap: snap, mediaPlaying: media, record: &record)

        case .keep(let reason):
            keep(segmentIDs, as: reason, from: movedFrom, record: &record)

        case .endRun(let content, let end):
            await endRun(content: content, end: end, transcript: transcript, segmentIDs: segmentIDs, record: &record)

        case .recover(let r):
            await recover(r, segmentIDs: segmentIDs, snap: snap, record: &record, generation: gen)
        }
    }

    /// Plain speech, a spoken start or more words for the run: to the dictation engine.
    private func dictateLocally(text: String, target: String?, start: Decision.Start, decision: Decision, segmentIDs: [Int],
                                snap: DesktopSnapshot, mediaPlaying: Bool, record: inout CommandRecord) async {
        record.tools = ["dictation"]
        let piece = DictationRun.Piece(text: text, ids: segmentIDs)
        let empty = TextMatching.words(text).isEmpty
        if !empty { buffer.claim(segmentIDs) }
        refreshLiveText()
        let report: DictationController.Report
        if start == .continuing, dictation.isRunning {
            report = await dictation.add(piece, at: lastSpeechEnd ?? Date())
        } else {
            report = await dictation.start(start, source: decision.source, app: target, snap: snap,
                                           mediaPlaying: mediaPlaying, first: empty ? nil : piece)
            // "Enter dictation into Claude Code": the start phrase itself was a command.
            if empty { buffer.dispose(segmentIDs, as: report.ok ? .acted : .kept(.nowhereToType)); recordDisposed() }
            if !report.ok { hud.model.show(.failure(report.message), for: 3.5) }
            else if empty { hud.model.show(.success(report.message + " — say “send it” or “done” when you're finished"), for: 2.5) }
        }
        record.decisions = ["dictation (\(start.rawValue), \(dictation.run?.model.mode.rawValue ?? "-")) → \(report.message)"]
        record.outcome = report.ok ? "ok" : "kept"
        record.disposition = empty ? (report.ok ? "acted" : "kept:nowhere_to_type") : (report.typedAny ? "typed" : (report.ok ? "waiting" : "kept"))
        record.actionDoneAt = Date().timeIntervalSince1970
        log.append(record)
        lastDictationRecordID = record.id
        if start == .implicit, report.ok { showImplicitHint() }
        finishLocal()
    }

    /// The first three times plain speech is typed, say why and how to undo it (spec §8).
    private func showImplicitHint() {
        guard settings.implicitHintsShown < 3 else { return }
        settings.implicitHintsShown += 1
        hud.model.showNote("I typed that because a text box was focused — say “that was a command” if it wasn't.")
    }

    /// Words that are neither a command nor typed: into the speech history. Background noise
    /// is kept silently; everything else gets a HUD line.
    private func keep(_ ids: [Int], as reason: KeptReason, from movedFrom: String?, record: inout CommandRecord) {
        buffer.dispose(ids, as: .kept(reason))
        recordDisposed()
        record.outcome = "kept"
        record.disposition = Disposition.kept(reason).label
        record.actionDoneAt = Date().timeIntervalSince1970
        log.append(record)
        refreshLiveText()
        switch reason {
        case .noise: break
        case .movedAway:
            hud.model.show(.info("You moved away from \(movedFrom ?? "where I was typing") — your words are kept: say “type it” to put them here"), for: 3.5)
        default:
            hud.model.show(.info("Kept your words — click a text box and say “type it”, or “copy it”"), for: 3)
        }
        finishLocal()
    }

    /// "Send it", "done", "cancel dictation" / "never mind" at the end of a run.
    private func endRun(content: String, end: Dictation.End, transcript: String, segmentIDs: [Int], record: inout CommandRecord) async {
        record.tools = ["dictation"]
        switch end {
        case .send, .done:
            if !TextMatching.words(content).isEmpty {
                buffer.claim(segmentIDs)
                _ = await dictation.add(DictationRun.Piece(text: content, ids: segmentIDs), at: lastSpeechEnd ?? Date())
            } else {
                buffer.dispose(segmentIDs, as: .acted)
                recordDisposed()
            }
            let report = await dictation.finish(end == .send ? .send : .done)
            record.decisions = ["dictation ended (\(end)) → \(report.message.isEmpty ? "ok" : report.message)"]
            if end == .send, report.ok {
                state = .executing
                hud.model.mode = .executing
                let out = await executor.execute(.submit(app: nil, sendPhrase: "send it"))
                record.decisions.append("submit → \(out.succeeded ? "ok" : "failed: \(out.message)")")
                record.irreversible = out.succeeded
                record.outcome = out.succeeded ? "ok" : "failed"
                record.results = [out.message]
                hud.model.show(out.succeeded ? .success(out.message) : .failure(out.message), for: 2.5)
            } else {
                record.outcome = report.ok ? "ok" : "failed"
                hud.model.show(report.ok ? .info("Done — not sent. Say “send” to send") : .failure(report.message), for: 2.5)
            }
            dictation.forgetLastRun()
        case .cancel:
            buffer.dispose(segmentIDs, as: .acted)
            recordDisposed()
            let age = Date().timeIntervalSince(dictation.run?.model.startedAt ?? Date())
            let effect = Dictation.cancelEffect(of: transcript, runAge: age)
            let report = await dictation.cancel(erase: effect == .erase)
            record.decisions = ["dictation \(effect == .erase ? "cancelled, erased" : "stopped, words kept") → \(report.message)"]
            record.outcome = report.ok ? "ok" : "failed"
            hud.model.show(.info(report.message), for: 2)
        }
        record.actionDoneAt = Date().timeIntervalSince1970
        log.append(record)
        finishLocal()
    }

    /// Recovery phrases, handled here with no router call (spec §5.6).
    private func recover(_ r: Dictation.Recovery, segmentIDs: [Int], snap: DesktopSnapshot, record: inout CommandRecord,
                         generation gen: Int) async {
        // The recovery phrase itself is a command that ran.
        buffer.dispose(segmentIDs, as: .acted)
        recordDisposed()
        record.tools = ["recovery"]
        var flash: HUDModel.Flash
        switch r {
        case .wasCommand:
            // I4: remove exactly what was typed, then route those words as a command.
            guard let words = await dictation.takeBackForCommand() else {
                flash = .failure("Nothing typed to take back")
                break
            }
            if let id = lastDictationRecordID { log.append(CorrectionRecord(commandID: id, sessionID: sessionID, how: "was_command")) }
            record.decisions = ["that was a command → removed what was typed, routing it"]
            record.outcome = "ok"
            record.actionDoneAt = Date().timeIntervalSince1970
            log.append(record)
            let id = hear(words)
            await route(transcript: words, segmentIDs: [id], generation: gen, intent: nil, focus: FocusKind.from(snap),
                        mediaPlaying: AudioCapture.outputIsPlaying(), dictationRun: nil)
            return
        case .typeInstead:
            // I5: undo the action if it can be undone, then type its words.
            var words: String?
            if let at = lastActedAt, Date().timeIntervalSince(at) < Self.recentWindow, let last = lastActedTranscript {
                words = last
                if let depth = lastActionUndoDepth, depth == executor.undoDepth {
                    let out = await executor.execute(.undoLast)
                    record.decisions.append("undo → \(out.succeeded ? "ok" : "failed: \(out.message)")")
                }
                if let id = lastActedRecordID { log.append(CorrectionRecord(commandID: id, sessionID: sessionID, how: "type_instead")) }
                lastActedAt = nil; lastActedTranscript = nil; lastActionUndoDepth = nil
            } else {
                words = speechHistory.lastKept?.text
            }
            guard let words else { flash = .failure("Nothing to type"); break }
            let report = await dictation.typeOnce(words, snap: await snapshots.refresh())
            record.decisions.append("type instead → \(report.message)")
            flash = report.ok ? .success(report.message) : .failure(report.message)
        case .scratchThat:
            let report = await dictation.scratch()
            record.decisions = ["scratch that → \(report.message)"]
            flash = report.ok ? .info(report.message) : .failure(report.message)
        case .typeKept(let about):
            guard let entry = about.flatMap({ speechHistory.kept(matching: $0) }) ?? (about == nil ? speechHistory.lastKept : nil) else {
                flash = .failure(about == nil ? "Nothing kept" : "Couldn't find kept words about “\(about!)”")
                break
            }
            let report = await dictation.typeOnce(entry.text, snap: snap)
            record.decisions = ["type kept → \(report.message)"]
            flash = report.ok ? .success(report.message) : .failure(report.message)
        case .copyKept(let about):
            guard let entry = about.flatMap({ speechHistory.kept(matching: $0) }) ?? (about == nil ? speechHistory.lastKept : nil) else {
                flash = .failure("Nothing kept to copy")
                break
            }
            PasteService.copy(entry.text)
            record.decisions = ["copy kept"]
            flash = .success("Copied “\(DesktopSnapshot.clip(entry.text, 50))”")
        case .listKept:
            let kept = speechHistory.kept(limit: 10)
            record.decisions = ["list kept (\(kept.count))"]
            if kept.isEmpty {
                flash = .info("Nothing kept")
            } else {
                hud.model.showCard(HelpCard(title: "Kept", subtitle: "Say “type the last one”, “copy the one about …”, or pick one from the menu bar",
                                            sections: [.init(title: "Newest first", items: kept.map { DesktopSnapshot.clip($0.text, 70) })]))
                flash = .info("Here's what I kept")
            }
        }
        record.outcome = record.outcome.isEmpty ? "ok" : record.outcome
        record.actionDoneAt = Date().timeIntervalSince1970
        log.append(record)
        hud.model.show(flash, for: 2.5)
        finishLocal()
    }

    /// After a local decision: back to listening, HUD in step.
    private func finishLocal() {
        guard isActive else { return }
        if state == .routing || state == .executing { state = muted ? .muted : (pending != nil ? .pending : .listening) }
        hud.model.mode = modeForIdle()
        hud.model.draftPreview = executor.draft.map { $0.typedText.isEmpty ? "(empty)" : $0.typedText }
        refreshLiveText()
    }

    private func route(transcript: String, raw: String? = nil, segmentIDs: [Int], generation gen: Int, intent: Decision?,
                       focus: FocusKind, mediaPlaying: Bool, dictationRun: String?) async {
        let previousState = state
        state = .routing
        hud.model.mode = .thinking
        let undoDepthBefore = executor.undoDepth
        var record = CommandRecord(sessionID: sessionID, generation: gen, transcript: transcript)
        record.rawTranscript = raw
        record.intent = intent?.logLine ?? "local: that was a command"
        record.segments = segmentIDs
        record.focusKind = focus.label
        record.mediaPlaying = mediaPlaying
        record.liveTranscript = hud.model.liveText
        record.speechEndAt = lastSpeechEnd?.timeIntervalSince1970
        record.transcriptFinalAt = Date().timeIntervalSince1970
        if let end = lastSpeechEnd { record.pauseMs = Int(Date().timeIntervalSince(end) * 1000) }
        record.segmentLagMs = lastSegmentLagMs
        record.transcribeMs = lastTranscribeMs

        let snap = await snapshots.current(since: lastSpeechStart)
        guard generation == gen, !Task.isCancelled else { restore(previousState); return }

        // The router sees where typed text would land, so plain prose can be dictation (spec §5.4),
        // and the run that was going, so a follow-up can continue it.
        var input = RouterInput(history: history.render(), snapshot: snap, draft: executor.draftForRouter,
                                pending: pending.map { "\($0.call.summary) — waiting for a spoken yes" }, transcript: transcript,
                                lastQuestion: history.lastQuestion, questionAbout: history.lastQuestionAbout,
                                focus: FocusKind.from(snap), dictationRun: dictationRun, mediaPlaying: mediaPlaying)
        var policy = ActionPolicy.ReplyEvaluator(context: PolicyContext(
            transcript: transcript, snapshot: snap, draftOpen: executor.draft != nil,
            draftText: executor.draft?.typedText ?? "", hasPending: pending != nil, pendingSummary: pending?.call.summary))

        var outcomeLines: [String] = []
        var acted = false, waited = false, ended = false, anyFailed = false, anyHeld = false, anySucceeded = false
        var dictated = false
        var kept: KeptReason?
        var asked = false
        var stopExecuting = false
        var lookAgain = false

        // What the stream did, for the log when no tool call comes back.
        var events = 0, lastStop: String?, replyText = ""

        func runReply(_ attempt: Int) async throws -> Bool {
            var sawTool = false
            let toolSeen = RouteFlag()
            record.requestSentAt = Date().timeIntervalSince1970
            let deadline = Date().addingTimeInterval(3)
            // Cancel this route only: a newer route may own `routeTask` by the time it fires.
            // 3 s to the first tool call; a long typed payload then gets up to 20 s to stream.
            let thisRoute = routeTask
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if toolSeen.on { try? await Task.sleep(nanoseconds: 17_000_000_000) }
                if !Task.isCancelled { thisRoute?.cancel() }
            }
            defer { watchdog.cancel() }
            for try await event in client.route(input) {
                guard generation == gen, !Task.isCancelled else { throw CancellationError() }
                events += 1
                switch event {
                case .toolStarted(_, let name, let at):
                    sawTool = true
                    toolSeen.on = true
                    if record.firstToolAt == nil { record.firstToolAt = at.timeIntervalSince1970 }
                    record.tools.append(name)
                case .toolCompleted(_, let name, let result, let raw, _):
                    guard !stopExecuting else { continue }
                    switch result {
                    case .failure(let err):
                        record.decisions.append("\(name): invalid input (\(err)) \(raw.prefix(120))")
                        anyFailed = true
                        outcomeLines.append("Couldn't understand the \(name) request")
                    case .success(let call):
                        let r = await handleCall(call, policy: &policy, record: &record, generation: gen,
                                                 segmentIDs: segmentIDs, mediaPlaying: mediaPlaying)
                        switch r {
                        case .waited: waited = true
                        case .dictated(let ok, let msg): dictated = true; if !ok { anyFailed = true }; outcomeLines.append(msg)
                        case .kept(let reason): kept = reason
                        case .asked(let question): acted = true; anySucceeded = true; asked = true; outcomeLines.append(question)
                        case .acted(let ok, let msg): acted = true; if ok { anySucceeded = true } else { anyFailed = true }; outcomeLines.append(msg)
                        case .held(let msg): anyHeld = true; outcomeLines.append(msg); stopExecuting = true
                        case .ended: ended = true; stopExecuting = true
                        case .rejected(let msg): anyFailed = true; outcomeLines.append(msg)
                        case .lookAgain: lookAgain = true
                        case .skipped: break
                        case .stale: throw CancellationError()
                        }
                    }
                case .finished(let stop, let usage):
                    record.usage = usage
                    lastStop = stop
                    if stop == "refusal" { throw RouterError.refusal }
                    if stop == "max_tokens" && !sawTool { throw RouterError.truncated }
                    if stop == "overloaded" { throw RouterError.overloaded }
                    if let s = stop, s.hasPrefix("error:") { throw RouterError.http(500, String(s.dropFirst(6))) }
                case .text(let t):
                    if replyText.count < 300 { replyText += t }
                case .firstInputDelta:
                    break
                }
                if Date() > deadline && !sawTool { throw RouterError.timeout }
            }
            // A cancelled task ends the stream quietly, with no events: that's newer speech (or
            // the watchdog), not an empty reply. 4 Nov's "Didn't catch that (events: 0)" were all this.
            if Task.isCancelled || generation != gen { throw CancellationError() }
            _ = attempt
            return sawTool
        }

        do {
            // No tool call, or a reply that ended early before any tool started: retry once on a
            // fresh connection (4 Nov: five "events: 0" failures, retries on the same one too).
            var got = false
            for attempt in 0..<2 {
                do {
                    got = try await runReply(attempt)
                } catch RouterError.incomplete(let detail) where attempt == 0 && record.tools.isEmpty {
                    record.mismatchNotes.append("first reply ended early: \(detail)")
                }
                if got || !record.tools.isEmpty { break }
                record.retried = true
                client.resetConnection()
            }
            if !got { throw RouterError.noToolCall }
        } catch is CancellationError {
            // Turn resumed or the watchdog fired.
            if generation == gen && !stopExecuting && !acted && record.tools.isEmpty && !timeoutRetried.contains(gen) {
                // No reply in 3 s and nothing ran: retry once on a fresh connection instead of
                // making them repeat it (4 Nov: "open the terminal" timed out twice).
                timeoutRetried.insert(gen)
                record.outcome = "cancelled"; record.error = "timed out, retrying" + diagnostics()
                finish(record, previousState: previousState, gen: gen)
                client.resetConnection()
                routeNow(generation: gen)
                return
            } else if generation == gen && !stopExecuting && !acted {
                record.outcome = "error"; record.error = RouterError.timeout.description + diagnostics()
                keepWords(after: RouterError.timeout.hudMessage)
            } else {
                record.outcome = "cancelled"
                // Newer speech came in after something already ran. The words are routed again
                // with it, so record what's done: the Netflix tab was switched to twice (9 Nov).
                if acted {
                    history.add(.init(transcript: transcript, actions: record.decisions, outcome: Self.doneWhileTalking))
                    lastActedRecordID = record.id
                }
            }
            finish(record, previousState: previousState, gen: gen)
            return
        } catch let e as RouterError {
            record.outcome = "error"; record.error = e.description + diagnostics()
            // Never auto-retry an action, and never drop the words: they stay in the buffer
            // and the next thing said is routed together with them.
            keepWords(after: e.hudMessage)
            finish(record, previousState: previousState, gen: gen)
            return
        } catch {
            record.outcome = "error"; record.error = "\(error)" + diagnostics()
            keepWords(after: "Router error — nothing ran")
            finish(record, previousState: previousState, gen: gen)
            return
        }

        func diagnostics() -> String {
            " (events: \(events), stop: \(lastStop ?? "none")\(replyText.isEmpty ? "" : ", text: \"\(replyText)\""))"
        }

        // A second look (9 Nov: "go back to YouTube and open this video" only switched the
        // tab). The router asked to see the screen its actions made: read it and finish.
        var followUps = 0
        while lookAgain, !stopExecuting, followUps < Self.maxFollowUps, generation == gen, !Task.isCancelled {
            lookAgain = false
            followUps += 1
            record.followUps = followUps
            state = .routing
            hud.model.mode = .thinking
            try? await Task.sleep(nanoseconds: 800_000_000)          // let the page or app settle
            guard generation == gen, !Task.isCancelled else { break }
            var fresh = await snapshots.refresh()
            if fresh.frontControls == nil {
                try? await Task.sleep(nanoseconds: 700_000_000)
                fresh = await snapshots.refresh()
            }
            guard generation == gen, !Task.isCancelled else { break }
            input = RouterInput(history: history.render(), snapshot: fresh, draft: executor.draftForRouter,
                                pending: pending.map { "\($0.call.summary) — waiting for a spoken yes" }, transcript: transcript,
                                alreadyDone: record.decisions)
            policy = ActionPolicy.ReplyEvaluator(context: PolicyContext(
                transcript: transcript, snapshot: fresh, draftOpen: executor.draft != nil,
                draftText: executor.draft?.typedText ?? "", hasPending: pending != nil, pendingSummary: pending?.call.summary))
            do {
                _ = try await runReply(followUps)
            } catch {
                record.mismatchNotes.append("follow-up \(followUps) stopped: \(error)")
                break
            }
        }

        // Segmentation (Final review 3): a reply that did something disposes of its words;
        // wait_for_more leaves them waiting (ReplyOutcome.disposition has the rules). Words handed
        // to the dictation engine are claimed, so it disposes them (typed or kept) itself.
        var reply = ReplyOutcome()
        reply.acted = acted; reply.waited = waited; reply.ended = ended; reply.failed = anyFailed
        reply.held = anyHeld; reply.succeeded = anySucceeded; reply.dictated = dictated; reply.asked = asked
        reply.kept = kept; reply.outcomeLines = outcomeLines.count
        if let disposition = reply.disposition {
            buffer.dispose(through: segmentIDs.last ?? -1, as: disposition)
            recordDisposed()
            record.disposition = dictated && !acted ? "typed" : disposition.label
        }
        if dictated {
            // Recorded for the router's context ("dictation just happened"), but not an action:
            // "type that instead" and "undo" don't refer to it.
            history.add(.init(transcript: transcript, actions: ["dictate"], outcome: outcomeLines.last ?? "typed"))
            lastDictationRecordID = record.id
        }
        if acted || anyHeld {
            // A command ran: the last run is no longer what "scratch that" means.
            lastActedAt = Date()
            lastSpokeToVantoAt = Date()
            lastActedTranscript = transcript
            lastActionUndoDepth = executor.undoDepth > undoDepthBefore ? executor.undoDepth : nil
            dictation.forgetLastRun()
        }
        // Everything that did something, failed or was refused goes in the history, so "not this
        // one" and "that was wrong" have something to refer to.
        if acted || anyHeld || (anyFailed && !waited) {
            history.add(.init(transcript: transcript, actions: record.decisions, outcome: outcomeLines.joined(separator: "; ")))
            lastActedRecordID = record.id
        }
        record.actionDoneAt = Date().timeIntervalSince1970
        record.outcome = anyHeld ? "pending" : ((acted || dictated) ? (anyFailed ? "failed" : "ok") : (waited ? "waiting" : (kept != nil ? "kept" : (anyFailed ? "rejected" : "ok"))))
        record.results = outcomeLines
        refreshLiveText()

        if let last = outcomeLines.last {
            if anyHeld {
                // Prompt stays on screen until approved or cancelled.
            } else if anyFailed {
                hud.model.show(.failure(last), for: 3)
            } else if acted || dictated {
                // Longer answers ("what can I do here") stay up long enough to read.
                hud.model.show(.success(last), for: max(1.8, Double(last.count) / 16))
            }
        }
        finish(record, previousState: previousState, gen: gen)
        if ended { end(reason: "spoken") }
    }

    private func restore(_ previous: State) {
        if state == .routing { state = pending != nil ? .pending : (previous == .speaking ? .speaking : .listening) }
    }

    /// A route failed: say so, but keep the words for the next try (3 Nov: a long prompt
    /// was thrown away on "Didn't catch that").
    private func keepWords(after failure: String) {
        hud.model.show(.failure("\(failure). Your words are kept: keep talking, or say “type it”"), for: 3)
    }

    /// Into the buffer, and noted in the ledger so a segment that never gets a disposition shows up
    /// as words lost.
    @discardableResult
    private func hear(_ text: String, endedAt: Date = Date(), raw: String? = nil) -> Int {
        let id = buffer.append(text, endedAt: endedAt, raw: raw)
        ledger.note(buffer)
        return id
    }

    /// Write the buffer's dispositions to the speech history, and to the log (per segment) for
    /// log-report's "words lost".
    private func recordDisposed() {
        let done = buffer.takeDisposed()
        guard !done.isEmpty else { return }
        ledger.record(done)
        speechHistory.append(done, sessionID: sessionID, app: snapshots.snapshot.frontmostApp?.name)
        for d in done {
            log.append(DispositionRecord(sessionID: sessionID, segments: d.segments.map(\.id), disposition: d.disposition.label, at: d.at))
        }
    }

    /// Segments heard this session that never got a disposition (must be 0), for the session record.
    private func wordsLost() -> Int {
        ledger.note(buffer)
        let lost = ledger.undisposed.count + ledger.doubled.count
        if lost > 0 { NSLog("VoiceCommand: words lost — undisposed \(ledger.undisposed), doubled \(ledger.doubled)") }
        return lost
    }

    private func finish(_ record: CommandRecord, previousState: State, gen: Int) {
        log.append(record)
        guard isActive else { return }
        if state == .routing || state == .executing {
            state = muted ? .muted : (pending != nil ? .pending : .listening)
        }
        if generation == gen { hud.model.mode = modeForIdle() }
        hud.model.draftPreview = executor.draft.map { $0.typedText.isEmpty ? "(empty)" : $0.typedText }
        hud.model.pendingPrompt = pending?.prompt
    }

    private enum CallResult {
        case waited, ended, stale, lookAgain, skipped
        /// Not acted on and not typed: into the speech history.
        case kept(KeptReason)
        /// Handed to the dictation engine, which types it or keeps it.
        case dictated(ok: Bool, String)
        /// `say` asking a question: the words wait for the answer.
        case asked(String)
        case acted(ok: Bool, String)
        case held(String)
        case rejected(String)
    }

    /// Apply policy, then execute or hold one call.
    private func handleCall(_ call: ToolCall, policy: inout ActionPolicy.ReplyEvaluator, record: inout CommandRecord, generation gen: Int,
                            segmentIDs: [Int], mediaPlaying: Bool) async -> CallResult {
        switch call {
        case .dictate(let target, let app, _):
            record.decisions.append(call.summary)
            // Settings: typing unasked is off, so the words are kept instead (spec §8).
            guard settings.implicitDictation || dictation.isRunning else {
                record.decisions.append("dictate → kept: typing unasked is off")
                return .kept(.unclear)
            }
            // The router's guess: Vanto types its own transcript, on a pause (TypingMode, source router).
            let ids = segmentIDs.filter { id in buffer.segments.contains { $0.id == id } }
            guard !ids.isEmpty else { return .skipped }   // already handed over (a second dictate in one reply)
            buffer.claim(ids)
            let piece = DictationRun.Piece(text: record.transcript, ids: ids)
            let report: DictationController.Report
            if dictation.isRunning {
                report = await dictation.add(piece, at: lastSpeechEnd ?? Date())
            } else {
                report = await dictation.start(.implicit, source: .router, app: target == .terminal ? "terminal" : app,
                                               snap: snapshots.snapshot, mediaPlaying: mediaPlaying, first: piece)
            }
            record.decisions.append("dictate → \(report.message)")
            return .dictated(ok: report.ok, report.message)
        case .waitForMore:
            record.decisions.append("wait_for_more")
            return .waited
        case .keep(let reason):
            record.decisions.append(call.summary)
            return .kept(reason)
        case .say(let message):
            record.decisions.append("say")
            return message.hasSuffix("?") ? .asked(message) : .acted(ok: true, message)
        case .endSession:
            record.decisions.append("end_session")
            return .ended
        case .lookAgain:
            record.decisions.append("look_again")
            return .lookAgain
        default:
            break
        }

        let decision = policy.next(call)
        switch decision {
        case .reject(let msg):
            record.decisions.append("\(call.summary) → rejected: \(msg)")
            return .rejected(msg)

        case .skip(let why):
            record.decisions.append("\(call.summary) → skipped: \(why)")
            return .skipped

        case .hold(let held, var prompt):
            record.decisions.append("\(held.summary) → pending")
            // Type, then confirm: a held terminal command is typed into its session first, so
            // "yes" runs exactly what's on screen.
            if case .terminalRun(_, let command, _, _) = held, await executor.pretype(held) {
                prompt = "Typed `\(command)` in the terminal. Run it? Say \"yes\" or \"no\"."
                record.decisions.append("pretyped")
            }
            pending = (held, prompt, record.id)
            state = .pending
            hud.model.pendingPrompt = prompt
            hud.model.mode = .pending
            return .held(prompt)

        case .run(let toRun, let minPauseMs, let note):
            if let note { record.mismatchNotes.append(note) }
            // Non-free actions wait for ~600 ms of pause and a current generation ID.
            if minPauseMs > 0, let end = lastSpeechEnd {
                let wait = Double(minPauseMs) / 1000 - Date().timeIntervalSince(end)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }
            guard generation == gen, !Task.isCancelled else { return .stale }

            switch toRun {
            case .cancelPending:
                if let p = pending { log.append(CorrectionRecord(commandID: p.recordID, sessionID: sessionID, how: "cancel_pending")) }
                pending = nil
                hud.model.pendingPrompt = nil
                await executor.clearPretyped()
                record.decisions.append("cancel_pending")
                return .acted(ok: true, "Cancelled")
            case .confirmPending:
                guard let p = pending else { return .rejected("Nothing is waiting for approval") }
                pending = nil
                hud.model.pendingPrompt = nil
                state = .executing
                hud.model.mode = .executing
                let out = executor.pretyped != nil ? await executor.runPretyped() : await executor.execute(p.call)
                record.decisions.append("confirm_pending → \(p.call.summary)")
                record.irreversible = out.succeeded
                return .acted(ok: out.succeeded, out.message)
            case .startDictation(let target, let app, _, let text):
                // A spoken start the router recognised: the same engine, typing on a pause.
                record.decisions.append(toRun.summary)
                let first = text.flatMap { TextMatching.words($0).isEmpty ? nil : DictationRun.Piece(text: $0) }
                let report = await dictation.start(.spoken, source: .router, app: target == .terminal ? "terminal" : app,
                                                   snap: snapshots.snapshot, mediaPlaying: mediaPlaying, first: first)
                hud.model.mode = modeForIdle()
                return .acted(ok: report.ok, report.ok ? "Dictating — say “send it” or “done” when you're finished" : report.message)
            default:
                break
            }

            // A new command replaces a pending one.
            if pending != nil, !isDraftAction(toRun) {
                if let p = pending { log.append(CorrectionRecord(commandID: p.recordID, sessionID: sessionID, how: "cancel_pending")) }
                pending = nil
                hud.model.pendingPrompt = nil
                await executor.clearPretyped()
            }
            if case .undoLast = toRun, let last = lastActedRecordID {
                log.append(CorrectionRecord(commandID: last, sessionID: sessionID, how: "undo"))
            }
            state = .executing
            hud.model.mode = .executing
            let terminalsBefore = Set(snapshots.snapshot.terminals.map(\.id))
            let out = await executor.execute(toRun)
            record.decisions.append("\(toRun.summary) → \(out.succeeded ? "ok" : "failed: \(out.message)")")
            if out.succeeded, case .terminalNew = toRun { await rememberNewTerminal(notIn: terminalsBefore) }
            if out.succeeded, case .describeScreen = toRun, let card = executor.lastCard { hud.model.showCard(card) }
            if out.succeeded, case .submit = toRun { record.irreversible = true }
            if out.succeeded, case .terminalRun = toRun { record.irreversible = true }
            return .acted(ok: out.succeeded, out.message)
        }
    }

    /// A terminal opened by voice is where the next commands go (4 Nov: "open a terminal,
    /// run ls" kept failing). The new tab shows up in a refresh within about a second.
    private func rememberNewTerminal(notIn before: Set<String>) async {
        for _ in 0..<4 {
            let snap = await snapshots.refresh()
            if let fresh = snap.terminals.first(where: { !before.contains($0.id) }) {
                snapshots.preferredShellID = fresh.id
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func isDraftAction(_ call: ToolCall) -> Bool {
        switch call {
        case .typeText, .newline, .clearTyped, .submit: return true
        default: return false
        }
    }
}
