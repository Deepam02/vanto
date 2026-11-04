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
    private var routeTask: Task<Void, Never>?
    private var scheduledRoute: Task<Void, Never>?
    private var ticker: Timer?
    private var observers: [NSObjectProtocol] = []
    private var unloadTimer: Timer?
    // Hold-Fn dictation: a session that only types what was said, no routing.
    private var dictationOnly = false
    private var dictated: [String] = []
    /// Dictation started by voice inside a command session ("write a message, wait for me"):
    /// speech is collected, not routed, until "send it", "done" or a long silence.
    private var voiceDictation: (target: TypeTarget, app: String?, sessionID: String?, chunks: [String], lastSpeech: Date)?
    private static let voiceDictationSilence: TimeInterval = 8
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

    init(speech: SpeechEngine, snapshots: SnapshotBuilder, executor: Executor, client: ClaudeClient, hud: HUDPanel, log: CommandLog) {
        self.speech = speech; self.snapshots = snapshots; self.executor = executor
        self.client = client; self.hud = hud; self.log = log
        speech.onEvent = { [weak self] e in self?.handle(e) }
        speech.capture.onDeviceChange = { [weak self] in
            guard let self, self.isActive else { return }
            self.end(reason: "mic changed", message: "Microphone changed — session ended")
        }
    }

    // MARK: Start / stop

    func toggle() {
        if dictationOnly { return }   // releasing Fn ends dictation
        if isActive { end(reason: "hotkey") } else { start() }
    }

    // MARK: Dictation (hold Fn)

    /// Hold Fn: listen and, on release, type everything said into the focused field.
    /// Local only (no API key, no router), so pauses and "um"s can't end or lose it.
    func startDictation() {
        guard state == .idle else { return }   // a command session already owns the mic
        unloadTimer?.invalidate()
        dictationOnly = true
        dictated = []
        sessionID = UUID().uuidString
        startedAt = Date()
        lastActivity = Date()
        buffer.reset(); partial = ""
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
        let text = settings.cleanUpDictation ? Dictation.clean(dictated) : Dictation.join(dictated)
        dictationOnly = false
        dictated = []

        var record = CommandRecord(sessionID: sessionID, generation: 0, transcript: text)
        record.tools = ["dictation"]
        let outcome: ExecOutcome = text.isEmpty ? .fail("Didn't hear anything") : await executor.dictate(text)
        record.decisions = ["dictate → \(outcome.succeeded ? "ok" : "failed: \(outcome.message)")"]
        record.results = [outcome.message]
        record.outcome = text.isEmpty ? "ignored" : (outcome.succeeded ? "ok" : "failed")
        record.actionDoneAt = Date().timeIntervalSince1970
        log.append(record)
        var session = SessionRecord(sessionID: sessionID, startedAt: startedAt, endedAt: Date(), endReason: "dictation")
        session.echoCancel = echoCancel
        log.append(session)

        state = .idle
        hud.model.liveText = ""
        hud.model.mode = .listening
        hud.model.show(outcome.succeeded ? .success(outcome.message) : .failure(outcome.message), for: 1.6)
        hideHUDSoon(after: 1.7)
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
        buffer.reset(); history.reset(); partial = ""; pending = nil; holdActive = false; muted = false
        voiceDictation = nil
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
        await speech.setVocabulary(extra: snap.apps.map(\.name) + ScreenVocabulary.terms(from: snap),
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
            // Cut short (mic changed, models failed): never lose what was said.
            dictationOnly = false
            let text = Dictation.join(dictated)
            dictated = []
            if !text.isEmpty {
                PasteService.copy(text)
                message = (message ?? "Dictation stopped") + " — your words are on the clipboard"
            }
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
        if voiceDictation != nil {
            // Ended mid-dictation: keep the words on the clipboard.
            let text = Dictation.join(voiceDictation!.chunks)
            voiceDictation = nil
            if !text.isEmpty { PasteService.copy(text); notes.append("dictation copied to the clipboard") }
        }
        executor.abandonPretyped()
        executor.endSession()
        var session = SessionRecord(sessionID: sessionID, startedAt: startedAt, endedAt: Date(), endReason: reason)
        session.echoCancel = echoCancel
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
        if buffer.dropStale(now: now) { refreshLiveText() }
        if let v = voiceDictation, state != .speaking, now.timeIntervalSince(v.lastSpeech) > Self.voiceDictationSilence {
            Task { await finishVoiceDictation(send: false, reason: "silence") }
        }
        // Idle time only; suspended while a draft is open, an action is pending, or after "hold on".
        let suspended = executor.draft != nil || pending != nil || holdActive || voiceDictation != nil ||
            state == .routing || state == .executing || state == .speaking
        if !suspended && !muted && now.timeIntervalSince(lastActivity) > Double(settings.idleTimeoutSec) {
            end(reason: "idle")
        }
    }

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
            if !muted { hud.model.mode = voiceDictation != nil ? .dictating : .speaking }
            voiceDictation?.lastSpeech = Date()

        case .partial(let text):
            partial = text
            refreshLiveText()

        case .segment(let text, let live, _, let endedAt, let transcribeMs):
            lastActivity = Date()
            partial = ""
            lastSpeechEnd = endedAt
            lastSegmentLagMs = Int(Date().timeIntervalSince(endedAt) * 1000)
            lastTranscribeMs = transcribeMs
            if speechStoppedScroll {
                speechStoppedScroll = false
                let said = text.isEmpty ? live : text
                if TextMatching.words(said).count <= 4 {
                    if state == .speaking { state = pending != nil ? .pending : .listening }
                    hud.model.mode = modeForIdle()
                    hud.model.show(.info("Stopped scrolling"), for: 1.2)
                    return
                }
            }
            if voiceDictation != nil && !muted {
                if state == .speaking { state = pending != nil ? .pending : .listening }
                voiceDictationSegment(text.isEmpty ? live : text)
                return
            }
            if muted {
                if TextMatching.contains(text, anyOf: ["resume", "resume listening", "start listening", "unpause"]) {
                    setMuted(false)
                    hud.model.show(.info("Listening again"), for: 1.2)
                }
                return
            }
            let id = buffer.append(text.isEmpty ? live : text, endedAt: endedAt)
            _ = id
            buffer.dropStale()
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
        case .segment(let text, let live, _, _, _):
            lastActivity = Date()
            partial = ""
            let words = text.isEmpty ? live : text
            if !words.isEmpty { dictated.append(words) }
        case .failure(let message):
            hud.model.show(.failure(message))
            return
        }
        hud.model.liveText = ([Dictation.join(dictated), partial].filter { !$0.isEmpty }).joined(separator: " ")
    }

    private func refreshLiveText() {
        let pieces = [buffer.latest, partial].filter { !$0.isEmpty }
        hud.model.liveText = pieces.joined(separator: " ")
    }

    private func modeForIdle() -> HUDModel.Mode {
        if muted { return .muted }
        if voiceDictation != nil { return .dictating }
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

        // Spoken mute is local: no round trip needed.
        if TextMatching.contains(transcript, anyOf: Self.mutePhrases) && words.count <= 5 {
            buffer.consumeAll()
            refreshLiveText()
            setMuted(true)
            return
        }
        // Thinking pauses: trailing filler/connectors always wait, without a router call.
        if settings.thinkingPauses, let last = words.last, Self.trailingWaitWords.contains(last) {
            hud.model.mode = modeForIdle()
            return
        }
        if Self.holdPhrases.contains(where: { TextMatching.normalized(transcript).hasSuffix($0) }) { holdActive = true }

        let segmentIDs = buffer.latestSegmentIDs
        routeTask?.cancel()
        routeTask = Task { [weak self] in
            await self?.route(transcript: transcript, segmentIDs: segmentIDs, generation: gen)
        }
    }

    private func route(transcript: String, segmentIDs: [Int], generation gen: Int) async {
        let previousState = state
        state = .routing
        hud.model.mode = .thinking
        var record = CommandRecord(sessionID: sessionID, generation: gen, transcript: transcript)
        record.liveTranscript = hud.model.liveText
        record.speechEndAt = lastSpeechEnd?.timeIntervalSince1970
        record.transcriptFinalAt = Date().timeIntervalSince1970
        if let end = lastSpeechEnd { record.pauseMs = Int(Date().timeIntervalSince(end) * 1000) }
        record.segmentLagMs = lastSegmentLagMs
        record.transcribeMs = lastTranscribeMs

        let snap = await snapshots.current(since: lastSpeechStart)
        guard generation == gen, !Task.isCancelled else { restore(previousState); return }

        let input = RouterInput(history: history.render(), snapshot: snap, draft: executor.draftForRouter,
                                pending: pending.map { "\($0.call.summary) — waiting for a spoken yes" }, transcript: transcript,
                                lastQuestion: history.lastQuestion)
        var policy = ActionPolicy.ReplyEvaluator(context: PolicyContext(
            transcript: transcript, snapshot: snap, draftOpen: executor.draft != nil,
            draftText: executor.draft?.typedText ?? "", hasPending: pending != nil, pendingSummary: pending?.call.summary))

        var outcomeLines: [String] = []
        var acted = false, waited = false, ignored = false, ended = false, anyFailed = false, anyHeld = false
        var stopExecuting = false

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
                        let r = await handleCall(call, policy: &policy, record: &record, generation: gen)
                        switch r {
                        case .waited: waited = true
                        case .ignored: ignored = true
                        case .acted(let ok, let msg): acted = true; if !ok { anyFailed = true }; outcomeLines.append(msg)
                        case .held(let msg): anyHeld = true; outcomeLines.append(msg); stopExecuting = true
                        case .ended: ended = true; stopExecuting = true
                        case .rejected(let msg): anyFailed = true; outcomeLines.append(msg)
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

        // Segmentation (Final review 3): actions or ignore move the cursor; wait_for_more doesn't.
        if acted || ignored || anyHeld || ended || anyFailed || !waited {
            buffer.consume(through: segmentIDs.last ?? -1)
        }
        // Everything that did something, failed or was refused goes in the history, so "not this
        // one" and "that was wrong" have something to refer to.
        if acted || anyHeld || (anyFailed && !waited) {
            history.add(.init(transcript: transcript, actions: record.decisions, outcome: outcomeLines.joined(separator: "; ")))
            lastActedRecordID = record.id
        }
        record.actionDoneAt = Date().timeIntervalSince1970
        record.outcome = anyHeld ? "pending" : (acted ? (anyFailed ? "failed" : "ok") : (waited ? "waiting" : (ignored ? "ignored" : (anyFailed ? "rejected" : "ok"))))
        record.results = outcomeLines
        refreshLiveText()

        if let last = outcomeLines.last {
            if anyHeld {
                // Prompt stays on screen until approved or cancelled.
            } else if anyFailed {
                hud.model.show(.failure(last), for: 3)
            } else if acted {
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
        case waited, ignored, ended, stale
        case acted(ok: Bool, String)
        case held(String)
        case rejected(String)
    }

    /// Apply policy, then execute or hold one call.
    private func handleCall(_ call: ToolCall, policy: inout ActionPolicy.ReplyEvaluator, record: inout CommandRecord, generation gen: Int) async -> CallResult {
        switch call {
        case .waitForMore:
            record.decisions.append("wait_for_more")
            return .waited
        case .ignore:
            record.decisions.append("ignore")
            return .ignored
        case .say(let message):
            record.decisions.append("say")
            return .acted(ok: true, message)
        case .endSession:
            record.decisions.append("end_session")
            return .ended
        default:
            break
        }

        let decision = policy.next(call)
        switch decision {
        case .reject(let msg):
            record.decisions.append("\(call.summary) → rejected: \(msg)")
            return .rejected(msg)

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
            case .startDictation(let target, let app, let sid, let text):
                voiceDictation = (target, app, sid, text.map { [$0] } ?? [], Date())
                record.decisions.append(toRun.summary)
                hud.model.mode = .dictating
                hud.model.liveText = text ?? ""
                return .acted(ok: true, "Dictating — say “send it” or “done” when you're finished")
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

    // MARK: Dictation started by voice

    /// One segment while dictating by voice: kept as content unless it ends the dictation.
    private func voiceDictationSegment(_ text: String) {
        guard voiceDictation != nil else { return }
        voiceDictation!.lastSpeech = Date()
        let (content, end) = Dictation.endCommand(in: text)
        if !content.isEmpty { voiceDictation!.chunks.append(content) }
        hud.model.liveText = Dictation.join(voiceDictation!.chunks)
        hud.model.mode = .dictating
        if let end {
            Task { await finishVoiceDictation(send: end == .send, cancel: end == .cancel, reason: "\(end)") }
        }
    }

    /// Type everything dictated (locally collected words, so no router limits), and send it
    /// if they said "send it".
    private func finishVoiceDictation(send: Bool, cancel: Bool = false, reason: String) async {
        guard let v = voiceDictation else { return }
        voiceDictation = nil
        let text = settings.cleanUpDictation ? Dictation.clean(v.chunks) : Dictation.join(v.chunks)
        var record = CommandRecord(sessionID: sessionID, generation: generation, transcript: text)
        record.tools = ["dictation"]
        hud.model.liveText = ""
        if cancel || text.isEmpty {
            record.outcome = "ignored"
            record.decisions = ["dictation ended (\(reason)), nothing typed"]
            log.append(record)
            hud.model.mode = modeForIdle()
            hud.model.show(.info(cancel ? "Dictation cancelled" : "Nothing dictated"), for: 1.6)
            return
        }
        state = .executing
        hud.model.mode = .executing
        var out = await executor.execute(.typeText(target: v.target, app: v.app, sessionID: v.sessionID, payload: text))
        record.decisions = ["dictation (\(reason)) → type_text: \(out.succeeded ? "ok" : "failed: \(out.message)")"]
        if out.succeeded && send {
            out = await executor.execute(.submit(app: v.app, sendPhrase: "send it"))
            record.decisions.append("submit → \(out.succeeded ? "ok" : "failed: \(out.message)")")
            record.irreversible = out.succeeded
        }
        record.outcome = out.succeeded ? "ok" : "failed"
        record.results = [out.message]
        record.actionDoneAt = Date().timeIntervalSince1970
        log.append(record)
        if state == .executing { state = pending != nil ? .pending : .listening }
        hud.model.mode = modeForIdle()
        hud.model.draftPreview = executor.draft.map { $0.typedText }
        hud.model.show(out.succeeded ? .success(out.message) : .failure(out.message), for: 2.5)
    }

    private func isDraftAction(_ call: ToolCall) -> Bool {
        switch call {
        case .typeText, .newline, .clearTyped, .submit: return true
        default: return false
        }
    }
}
