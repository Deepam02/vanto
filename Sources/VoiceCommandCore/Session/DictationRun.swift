import Foundation

/// One dictation run (spec §5.5): how it started, how it types, what it typed so far and
/// what is still waiting to be typed. Pure state, so it can be tested; the app's
/// DictationController does the typing and reports each result back here.
public struct DictationRun: Sendable {
    /// Words handed to the run, with the buffer segments they came from (none for words that
    /// aren't in the buffer, such as a kept item typed again).
    public struct Piece: Equatable, Sendable {
        public var text: String
        public var ids: [Int]
        public init(text: String, ids: [Int] = []) { self.text = text; self.ids = ids }
    }

    /// One paste, or one live step, exactly as typed.
    public struct Chunk: Equatable, Sendable {
        /// What was typed, with its leading space.
        public var text: String
        /// What was backspaced first (a period the run typed itself, mid-sentence).
        public var replaced: String
        /// The words as said, for "that was a command".
        public var spoken: String
        public var ids: [Int]
    }

    public let start: Decision.Start
    public let mode: TypingMode
    /// Where it types, for the HUD ("Claude Code").
    public let target: String
    public let startedAt: Date
    /// When the last words for it were said (silence ends the run, a pause pastes).
    public private(set) var lastSpeech: Date
    public private(set) var chunks: [Chunk] = []
    /// Handed to the run, not typed yet (paste-on-pause, or live typing in progress).
    public private(set) var waiting: [Piece] = []
    /// The run's text in the field: every chunk, minus what later chunks backspaced.
    public private(set) var typed = ""
    /// The field already had text right before the run started, so the first chunk gets a space.
    public var leadingSpace: Bool

    /// Paste-on-pause pastes once speech has paused this long.
    public static let pasteDelay: TimeInterval = 1.2
    /// Silence that ends a run: 8 s after a spoken start, 4 s after an implicit one.
    public static let spokenSilence: TimeInterval = 8
    public static let implicitSilence: TimeInterval = 4

    public init(start: Decision.Start, mode: TypingMode, target: String, at: Date = Date(), leadingSpace: Bool = false) {
        self.start = start; self.mode = mode; self.target = target
        self.startedAt = at; self.lastSpeech = at; self.leadingSpace = leadingSpace
    }

    public mutating func add(_ piece: Piece, at: Date = Date()) {
        lastSpeech = max(lastSpeech, at)
        guard !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !piece.ids.isEmpty else { return }
        waiting.append(piece)
    }

    /// Speech is still going: not a pause, not silence.
    public mutating func heard(at: Date = Date()) { lastSpeech = max(lastSpeech, at) }

    /// What to type next for everything waiting: one mended step (`Dictation.mend`), and the
    /// pieces it covers. Nil when nothing is waiting.
    public func nextStep(cleanUp: Bool = true) -> (mend: Dictation.Mend, pieces: [Piece])? {
        guard !waiting.isEmpty else { return nil }
        let joined = Dictation.join(waiting.map(\.text))
        var mend = Dictation.mend(typed: typed, next: joined, cleanUp: cleanUp)
        if typed.isEmpty, leadingSpace, !mend.text.isEmpty { mend.text = " " + mend.text }
        return (mend, waiting)
    }

    /// The step was typed: the pieces leave `waiting` and become a chunk.
    public mutating func didType(_ mend: Dictation.Mend, pieces: [Piece]) {
        removeWaiting(pieces)
        let back = min(mend.backspaces, typed.count)
        let replaced = String(typed.suffix(back))
        typed = String(typed.dropLast(back)) + mend.text
        chunks.append(Chunk(text: mend.text, replaced: replaced, spoken: Dictation.join(pieces.map(\.text)),
                            ids: pieces.flatMap(\.ids)))
    }

    /// The pieces couldn't be typed: they leave `waiting` (the caller keeps them).
    public mutating func didNotType(_ pieces: [Piece]) { removeWaiting(pieces) }

    /// Everything still waiting, which leaves the run (it ended before typing them).
    public mutating func takeWaiting() -> [Piece] {
        defer { waiting.removeAll() }
        return waiting
    }

    /// "Scratch that": the last chunk leaves the run. The caller backspaces `text` and types
    /// `replaced` back.
    public mutating func removeLastChunk() -> Chunk? {
        guard let last = chunks.popLast() else { return nil }
        typed = String(typed.dropLast(last.text.count)) + last.replaced
        return last
    }

    /// "That was a command": everything the run typed leaves it. The caller backspaces
    /// `chars`; `spoken` is what to route instead.
    public mutating func removeAll() -> (chars: Int, spoken: String, ids: [Int]) {
        let out = (typed.count, spokenText, chunks.flatMap(\.ids))
        chunks.removeAll()
        typed = ""
        return out
    }

    /// The words as said, typed or waiting.
    public var spokenText: String { Dictation.join(chunks.map(\.spoken) + waiting.map(\.text)) }

    /// The text so far ends mid-sentence ("…we should."), so the next words continue it.
    public var endsMidSentence: Bool {
        let last = TextMatching.words(typed).last?.norm ?? ""
        return Dictation.dangling.contains(last) || Dictation.fillers.contains(last)
    }

    /// Paste-on-pause: something is waiting and speech has paused long enough.
    public func pasteDue(now: Date = Date(), speaking: Bool) -> Bool {
        mode == .onPause && !waiting.isEmpty && !speaking && now.timeIntervalSince(lastSpeech) >= Self.pasteDelay
    }

    /// Silence long enough to end the run (spec §5.5). Hold Fn ends on release instead.
    public func silenceEnds(now: Date = Date(), speaking: Bool) -> Bool {
        guard mode != .onRelease, !speaking else { return false }
        let limit = start == .implicit ? Self.implicitSilence : Self.spokenSilence
        return now.timeIntervalSince(lastSpeech) > limit
    }

    private mutating func removeWaiting(_ pieces: [Piece]) {
        // Pieces only join at the end and leave from the front, so a prefix is what was taken.
        if waiting.starts(with: pieces) { waiting.removeFirst(pieces.count); return }
        for p in pieces { if let i = waiting.firstIndex(of: p) { waiting.remove(at: i) } }
    }
}
