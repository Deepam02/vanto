import Foundation

/// What one router reply did, enough to say where the words it covered go
/// (docs/specs/never-lose-dictation.md §3). SessionController fills it in as tool calls
/// come back; the session invariant test drives it with random replies.
public struct ReplyOutcome: Equatable, Sendable {
    /// A tool call ran (successfully or not), or a question was asked.
    public var acted = false
    /// wait_for_more: the person isn't finished.
    public var waited = false
    /// end_session.
    public var ended = false
    public var failed = false
    /// Held for a spoken yes.
    public var held = false
    public var succeeded = false
    /// Handed to the dictation engine, which disposes its claimed words itself.
    public var dictated = false
    /// `say` asked a question.
    public var asked = false
    /// keep(reason).
    public var kept: KeptReason?
    /// Lines the reply showed (a lone question means it only asked).
    public var outcomeLines = 0
    /// The router errored or timed out (after its one retry) and nothing ran.
    public var errored = false

    public init() {}

    /// Where the words go, or nil to leave them waiting: wait_for_more, so the next thing
    /// said is routed with them. Failed or kept words are kept, never dropped. Words a lone
    /// question was about are kept too (the answer completes them through asked_about), so an
    /// unanswered "which app?" doesn't lose them. Words a route failed on are kept (error)
    /// right away, so "type it" brings them back and a later command can't take them as acted.
    public var disposition: Disposition? {
        if errored && !acted && !held && !dictated { return .kept(.error) }
        guard acted || kept != nil || held || ended || failed || dictated || !waited else { return nil }
        if asked && !held && !ended && outcomeLines == 1 { return .kept(.unclear) }
        if held || ended || succeeded { return .acted }
        if failed { return .kept(.failed) }
        if let kept { return .kept(kept) }
        return .acted
    }
}

/// A tripwire for invariant I1: every segment heard gets exactly one disposition, and that
/// disposition reaches the speech history. SessionController notes what it hears and what it
/// writes to the history; at session end anything heard but never written is words lost,
/// logged on the session record (log-report's "words lost", which must be 0).
public struct DispositionLedger: Sendable {
    /// Segment IDs heard this session.
    public private(set) var heard: Set<Int> = []
    /// How many dispositions each segment got (must end at exactly 1).
    public private(set) var counts: [Int: Int] = [:]

    public init() {}

    /// Note every segment the buffer holds (waiting or claimed). Call after each append.
    public mutating func note(_ buffer: TranscriptBuffer) {
        for s in buffer.segments { heard.insert(s.id) }
        for s in buffer.claimed { heard.insert(s.id) }
    }

    /// Dispositions collected from the buffer (`takeDisposed`) on their way to the history.
    public mutating func record(_ disposed: [TranscriptBuffer.Disposed]) {
        for d in disposed {
            for s in d.segments {
                heard.insert(s.id)
                counts[s.id, default: 0] += 1
            }
        }
    }

    /// Heard, but no disposition written.
    public var undisposed: [Int] { heard.filter { counts[$0] == nil }.sorted() }
    /// More than one disposition.
    public var doubled: [Int] { counts.filter { $0.value > 1 }.map(\.key).sorted() }

    /// A new session.
    public mutating func reset() {
        heard.removeAll()
        counts.removeAll()
    }
}
