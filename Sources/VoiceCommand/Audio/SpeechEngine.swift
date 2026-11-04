import AVFoundation
import CoreML
import FluidAudio

/// Speech pipeline (Final review point 2):
/// - Silero VAD on every 256 ms chunk decides when speech starts and ends.
/// - While speaking, the streaming Parakeet EOU model produces live text for the HUD.
/// - When a speech segment ends, it is re-transcribed with Parakeet TDT v2 plus custom
///   vocabulary boosting; that text is what the router sees.
/// Everything runs in one consumer task, in order, so model calls never interleave.
final class SpeechEngine: @unchecked Sendable {
    enum Event {
        case speechStarted(at: Date)
        case partial(String)
        case segment(text: String, live: String, startedAt: Date, endedAt: Date, transcribeMs: Int)
        case failure(String)
    }

    /// Delivered on the main thread.
    var onEvent: ((Event) -> Void)?
    let capture = AudioCapture()

    private var vad: VadManager?
    private var eou: StreamingEouAsrManager?
    private var asr: AsrManager?
    private var ctcModels: CtcModels?
    private var vocab: VocabularyBoostingSession?

    private var stream: AsyncStream<[Float]>.Continuation?
    private var consumer: Task<Void, Never>?
    private let loadLock = NSLock()
    private(set) var modelsLoaded = false

    static let sampleRate = 16_000
    static let baseVocabulary = [
        // Not "Claude Code": boosting it turned a plain "Claude" into "Claude Code" (4 Nov).
        "Cursor", "Claude", "Ghostty", "iTerm", "npm", "GitHub", "ChatGPT", "Codex",
        "Slack", "pnpm", "localhost", "Vercel", "Linear", "Chrome", "PR", "README",
        // Sites people say by name. "Xcode" is left out: boosting it turned "X.com" into
        // "Xcode" (3 Nov log); running apps are added per session anyway.
        "x.com", "Twitter", "LinkedIn", "Netflix", "YouTube", "Gmail", "Notion", "Figma",
    ]

    // MARK: Models

    /// Downloads (first launch) and loads all models. `progress` gets 0…1, always on the main thread.
    func loadModels(progress: @escaping @Sendable (Double) -> Void) async throws {
        if modelsLoaded { return }
        let report: @Sendable (Double, Double, Double) -> Void = { base, weight, f in
            DispatchQueue.main.async { progress(min(1, base + weight * f)) }
        }
        let vad = try await VadManager(config: VadConfig(defaultThreshold: 0.5)) { p in report(0, 0.05, p.fractionCompleted) }
        let eou = StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 640)
        try await eou.loadModels(progressHandler: { p in report(0.05, 0.2, p.fractionCompleted) })
        let models = try await AsrModels.downloadAndLoad(version: .v2, progressHandler: { p in report(0.25, 0.6, p.fractionCompleted) })
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        report(0.85, 0, 0)
        // Custom vocabulary needs the separate CTC 110M encoder for TDT 0.6B models.
        let ctc = try? await CtcModels.downloadAndLoad(variant: .ctc110m)
        report(1, 0, 0)

        loadLock.withLock {
            self.vad = vad; self.eou = eou; self.asr = asr; self.ctcModels = ctc
            modelsLoaded = true
        }
    }

    /// Shell commands and sites with the ways they get misheard (3–4 Nov log): the alias
    /// is what the audio sounds like, the term is what gets written.
    static let spokenAliases: [(String, [String])] = [
        // No spelled-out letters ("p w d"): they matched letters inside names ("B Pwd O" for Blooio).
        ("ls", ["el es", "ellis"]), ("pwd", ["twd", "pee double you dee"]), ("cd", ["see dee"]),
        ("git status", ["get status"]), ("npm", ["en pee em"]), ("mkdir", ["make dir", "em kay dir"]),
        ("x.com", ["x dot com", "ex dot com"]),
    ]

    /// Rebuild the vocabulary for this session: built-in words and aliases, the person's own
    /// dictionary, and names from the screen (apps, tab and window titles, folders).
    func setVocabulary(extra: [String], personal: [(String, [String])] = []) async {
        guard let ctc = ctcModels else { return }
        var seen = Set<String>()
        var terms: [CustomVocabularyTerm] = []
        for (text, aliases) in personal + Self.spokenAliases where seen.insert(text.lowercased()).inserted {
            terms.append(CustomVocabularyTerm(text: text, aliases: aliases.isEmpty ? nil : aliases))
        }
        for word in Self.baseVocabulary + extra {
            let w = word.trimmingCharacters(in: .whitespaces)
            if w.count >= 2, seen.insert(w.lowercased()).inserted { terms.append(CustomVocabularyTerm(text: w)) }
        }
        vocab = try? await VocabularyBoostingSession(vocabulary: CustomVocabularyContext(terms: terms), ctcModels: ctc)
    }

    /// Free the models after a long idle period (they reload on the next session).
    func unloadModels() async {
        await eou?.cleanup()
        await asr?.cleanup()
        loadLock.withLock {
            vad = nil; eou = nil; asr = nil; ctcModels = nil; vocab = nil
            modelsLoaded = false
        }
    }

    // MARK: Listening

    func startListening(useBuiltIn: Bool, cancelEcho: Bool) throws {
        guard modelsLoaded, consumer == nil else { return }
        let (s, cont) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        stream = cont
        let startedAt = Date()
        consumer = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var state = PipelineState(sessionStart: startedAt)
            await self.eou?.reset()
            for await samples in s {
                await self.process(samples, &state)
            }
            // Session ended mid-speech: the partial segment is dropped.
            await self.eou?.reset()
        }
        capture.onSamples = { [weak self] samples in self?.stream?.yield(samples) }
        do { try capture.start(useBuiltIn: useBuiltIn, cancelEcho: cancelEcho) } catch {
            stopListening()
            throw error
        }
    }

    /// Stop the mic but keep the speech in progress: a second of silence closes the last
    /// segment, and its `.segment` event is delivered before this returns (dictation).
    func finishListening() async {
        capture.stop()
        capture.onSamples = nil
        stream?.yield([Float](repeating: 0, count: Self.sampleRate))
        stream?.finish()
        stream = nil
        let running = consumer
        consumer = nil
        await running?.value
        // Segment events are queued on main before the consumer ends; let them run first.
        await Task.yield()
    }

    func stopListening() {
        capture.stop()
        capture.onSamples = nil
        stream?.finish()
        stream = nil
        consumer = nil
    }

    /// Debug: run an audio file through the exact pipeline (VAD → streaming EOU → TDT),
    /// in mic-sized chunks, followed by 2 s of silence so the last segment closes.
    func simulate(file url: URL) async throws {
        let samples = try AudioConverter().resampleAudioFile(url) + [Float](repeating: 0, count: 2 * Self.sampleRate)
        var state = PipelineState(sessionStart: Date())
        await eou?.reset()
        var i = 0
        while i < samples.count {
            let end = min(i + 683, samples.count)      // ~43 ms, like a 2048-frame 48 kHz tap
            await process(Array(samples[i..<end]), &state)
            i = end
        }
    }

    // MARK: Pipeline

    private struct PipelineState {
        let sessionStart: Date
        var vadState = VadStreamState.initial()
        var pending: [Float] = []
        var preRoll: [Float] = []
        var segment: [Float] = []
        var inSpeech = false
        var segmentStart = Date()
        var processedSamples = 0
        var lastPartial = ""
        init(sessionStart: Date) { self.sessionStart = sessionStart }
    }

    private static let vadChunk = VadManager.chunkSize          // 4096 samples = 256 ms
    private static let preRollSamples = 8192                    // keep 0.5 s before speech starts
    /// minSilenceDuration 0.1 s: on 256 ms chunks the end is confirmed on the second silent
    /// chunk (~0.5 s after you stop) instead of the third. Extra splits at short pauses are
    /// harmless; segments join in the transcript buffer and routing waits for the last one.
    private static let segmentation = VadSegmentationConfig(
        minSpeechDuration: 0.15, minSilenceDuration: 0.1, maxSpeechDuration: 14.0, speechPadding: 0.1)

    private func emit(_ e: Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(e) }
    }

    private func process(_ samples: [Float], _ st: inout PipelineState) async {
        guard let vad else { return }
        st.pending.append(contentsOf: samples)
        while st.pending.count >= Self.vadChunk {
            let chunk = Array(st.pending.prefix(Self.vadChunk))
            st.pending.removeFirst(Self.vadChunk)
            let chunkStartSample = st.processedSamples
            st.processedSamples += chunk.count

            let result: VadStreamResult
            do {
                result = try await vad.processStreamingChunk(chunk, state: st.vadState, config: Self.segmentation)
            } catch {
                emit(.failure("Voice detection failed: \(error.localizedDescription)"))
                continue
            }
            st.vadState = result.state

            if st.inSpeech {
                st.segment.append(contentsOf: chunk)
                await feedStreaming(chunk, &st)
            } else {
                st.preRoll.append(contentsOf: chunk)
                if st.preRoll.count > Self.preRollSamples { st.preRoll.removeFirst(st.preRoll.count - Self.preRollSamples) }
            }

            guard let event = result.event else { continue }
            let eventTime = st.sessionStart.addingTimeInterval(Double(event.sampleIndex) / Double(Self.sampleRate))
            if event.isStart && !st.inSpeech {
                st.inSpeech = true
                st.segmentStart = eventTime
                st.segment = st.preRoll                      // pre-roll already includes this chunk
                st.preRoll.removeAll()
                st.lastPartial = ""
                await eou?.reset()
                await feedStreaming(st.segment, &st)
                emit(.speechStarted(at: eventTime))
            } else if event.isEnd && st.inSpeech {
                st.inSpeech = false
                // Trim trailing silence past the end sample, keeping VAD padding.
                let keep = max(0, st.segment.count - (chunkStartSample + chunk.count - event.sampleIndex))
                let audio = Array(st.segment.prefix(max(keep, Self.sampleRate / 4)))
                let live = st.lastPartial
                st.segment.removeAll()
                await eou?.reset()
                let t0 = Date()
                let text = await transcribe(audio) ?? live
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                emit(.segment(text: text, live: live, startedAt: st.segmentStart, endedAt: eventTime, transcribeMs: ms))
            }
        }
    }

    private func feedStreaming(_ samples: [Float], _ st: inout PipelineState) async {
        guard let eou, let buffer = Self.pcmBuffer(samples) else { return }
        _ = try? await eou.process(audioBuffer: buffer)
        let partial = await eou.getPartialTranscript()
        if partial != st.lastPartial {
            st.lastPartial = partial
            emit(.partial(partial))
        }
    }

    /// Batch Parakeet TDT v2 with vocabulary rescoring. Short clips are padded to 1 s.
    private func transcribe(_ audio: [Float]) async -> String? {
        guard let asr, !audio.isEmpty else { return nil }
        var samples = audio
        if samples.count < Self.sampleRate { samples.append(contentsOf: [Float](repeating: 0, count: Self.sampleRate - samples.count)) }
        do {
            var decoderState = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
            let result = try await asr.transcribe(samples, decoderState: &decoderState)
            var text = result.text
            if let vocab, let timings = result.tokenTimings,
               vocab.hasCTCRescoringCandidates(text: text, tokenTimings: timings),
               let rescored = await vocab.rescore(text: text, tokenTimings: timings, audioSamples: samples),
               rescored.wasModified {
                text = rescored.text
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            emit(.failure("Transcription failed: \(error.localizedDescription)"))
            return nil
        }
    }

    static func pcmBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buf
    }
}
