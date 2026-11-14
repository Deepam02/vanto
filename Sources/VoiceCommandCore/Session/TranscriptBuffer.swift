import Foundation

/// Where a finished speech segment ended up (docs/specs/never-lose-dictation.md §3).
/// Every segment gets exactly one: words are never just dropped.
public enum Disposition: Equatable, Hashable, Sendable {
    /// Part of a command that ran, or one waiting for a spoken yes.
    case acted
    /// Pasted into a text field as dictation.
    case typed
    /// Not acted on and not typed. In the speech history, where "type it" can get it back.
    case kept(KeptReason)
    /// The person removed it ("scratch that", "cancel dictation"). Still in the history.
    case discarded

    /// Kept and discarded words are what the menu's Kept list shows.
    public var isKept: Bool {
        switch self {
        case .kept, .discarded: return true
        case .acted, .typed: return false
        }
    }
}

/// Why words were kept rather than acted on or typed.
public enum KeptReason: String, Codable, Hashable, Sendable, CaseIterable {
    /// Background speech (a video, someone else in the room).
    case noise
    /// Said, but not to Vanto.
    case notForMe = "not_for_me"
    case unclear
    /// Left waiting more than `TranscriptBuffer.maxPendingAge`.
    case stale
    /// The action they asked for failed.
    case failed
    /// The router errored or timed out.
    case error
    /// No text field to type into.
    case nowhereToType = "nowhere_to_type"
    /// Focus moved to another app mid-dictation.
    case movedAway = "moved_away"
    /// The session ended with the words still waiting.
    case sessionEnded = "session_ended"
    /// "Never mind" after a dictation that was already a few seconds long.
    case neverMind = "never_mind"
}

extension Disposition: Codable {
    /// One flat string in the history file: "acted", "typed", "kept:stale", "discarded".
    public var label: String {
        switch self {
        case .acted: return "acted"
        case .typed: return "typed"
        case .kept(let r): return "kept:\(r.rawValue)"
        case .discarded: return "discarded"
        }
    }

    public init?(label: String) {
        switch label {
        case "acted": self = .acted
        case "typed": self = .typed
        case "discarded": self = .discarded
        default:
            guard label.hasPrefix("kept:"), let r = KeptReason(rawValue: String(label.dropFirst(5))) else { return nil }
            self = .kept(r)
        }
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        // An unknown reason from a newer build still reads as kept.
        self = Disposition(label: s) ?? (s.hasPrefix("kept") ? .kept(.unclear) : .acted)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(label)
    }
}

/// One transcript buffer per session (Final review point 3), with the never-lose contract.
///
/// Speech arrives as segments (one per voice-activity run). A segment waits in `segments`
/// until something decides what it was; it leaves only through `dispose(_:as:)`, which
/// records the decision in `disposed` for the caller to collect and write to the speech
/// history. The waiting segments form the latest utterance the router sees.
public struct TranscriptBuffer: Sendable {
    public struct Segment: Equatable, Sendable {
        public let id: Int
        public var text: String
        public let endedAt: Date
        /// What speech recognition heard before vocabulary boosting, when boosting changed it.
        public var raw: String?
    }

    /// Segments that left the buffer together, and where they went.
    public struct Disposed: Equatable, Sendable {
        public let segments: [Segment]
        public let disposition: Disposition
        public let at: Date
        public var text: String { segments.map(\.text).joined(separator: " ") }
        public var raw: String? {
            guard segments.contains(where: { $0.raw != nil }) else { return nil }
            return segments.map { $0.raw ?? $0.text }.joined(separator: " ")
        }
    }

    /// Segments still waiting for a disposition, oldest first.
    public private(set) var segments: [Segment] = []
    /// Segments handed to a dictation run: out of the next utterance, but still waiting for
    /// the run to say whether they were typed or kept.
    public private(set) var claimed: [Segment] = []
    /// Dispositions made since the caller last collected them (`takeDisposed`).
    public private(set) var disposed: [Disposed] = []
    private var nextID = 0
    /// Waiting speech older than this is kept (`.kept(.stale)`). Long enough for a thinking
    /// pause in the middle of a dictated prompt.
    public var maxPendingAge: TimeInterval = 120

    public init() {}

    @discardableResult
    public mutating func append(_ text: String, endedAt: Date = Date(), raw: String? = nil) -> Int {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = nextID
        nextID += 1
        guard !clean.isEmpty else { return id }
        segments.append(Segment(id: id, text: clean, endedAt: endedAt, raw: raw))
        return id
    }

    /// The waiting text, segments joined by single spaces.
    public var latest: String {
        segments.map(\.text).joined(separator: " ")
    }

    /// `latest` as heard before vocabulary boosting, or nil when boosting changed nothing.
    public var latestRaw: String? {
        guard segments.contains(where: { $0.raw != nil }) else { return nil }
        return segments.map { $0.raw ?? $0.text }.joined(separator: " ")
    }

    public var latestSegmentIDs: [Int] { segments.map(\.id) }

    public var hasPending: Bool { !segments.isEmpty || !claimed.isEmpty }

    /// Hand waiting segments to a dictation run. They leave `latest` (the next utterance) but
    /// still need a disposition: the run disposes them as typed or kept.
    public mutating func claim(_ ids: [Int]) {
        let wanted = Set(ids)
        claimed += segments.filter { wanted.contains($0.id) }
        segments.removeAll { wanted.contains($0.id) }
    }

    /// The only way out of the buffer. IDs that aren't waiting (already disposed, or never
    /// had words) are ignored, so a segment can't get two dispositions.
    public mutating func dispose(_ ids: [Int], as disposition: Disposition, at: Date = Date()) {
        let wanted = Set(ids)
        let leaving = (claimed + segments).filter { wanted.contains($0.id) }.sorted { $0.id < $1.id }
        guard !leaving.isEmpty else { return }
        segments.removeAll { wanted.contains($0.id) }
        claimed.removeAll { wanted.contains($0.id) }
        disposed.append(Disposed(segments: leaving, disposition: disposition, at: at))
    }

    /// Every unclaimed waiting segment up to and including `segmentID` (what one router reply covered).
    public mutating func dispose(through segmentID: Int, as disposition: Disposition, at: Date = Date()) {
        dispose(segments.filter { $0.id <= segmentID }.map(\.id), as: disposition, at: at)
    }

    public mutating func disposeAll(as disposition: Disposition, at: Date = Date()) {
        dispose(latestSegmentIDs, as: disposition, at: at)
    }

    /// Keep waiting segments that ended more than `maxPendingAge` ago (`.kept(.stale)`):
    /// out of the next request, but not lost. Returns true if any were kept.
    @discardableResult
    public mutating func keepStale(now: Date = Date()) -> Bool {
        let old = segments.prefix { now.timeIntervalSince($0.endedAt) > maxPendingAge }.map(\.id)
        dispose(old, as: .kept(.stale), at: now)
        return !old.isEmpty
    }

    /// Collect the dispositions made since the last call, oldest first.
    public mutating func takeDisposed() -> [Disposed] {
        defer { disposed.removeAll() }
        return disposed
    }

    /// End of a session: whatever is still waiting, claimed or not, is kept, never silently
    /// cleared. Collect `disposed` afterwards.
    public mutating func reset(at: Date = Date()) {
        dispose((claimed + segments).map(\.id), as: .kept(.sessionEnded), at: at)
    }
}

/// Short memory of what this session already did, for "close that" / "undo".
public struct SessionHistory: Sendable {
    public struct Entry: Equatable, Sendable {
        public let transcript: String
        public let actions: [String]
        public let outcome: String
        public let at: Date
        public init(transcript: String, actions: [String], outcome: String, at: Date = Date()) {
            self.transcript = transcript; self.actions = actions; self.outcome = outcome; self.at = at
        }
    }

    public private(set) var entries: [Entry] = []
    public var limit = 10

    public init() {}

    public mutating func add(_ entry: Entry) {
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    public mutating func reset() { entries.removeAll() }

    /// Oldest first; the last line is marked, so "not this one" / "that was wrong" has a referent.
    public func render() -> String {
        guard !entries.isEmpty else { return "(no commands yet this session)" }
        return entries.enumerated().map { i, e in
            let mark = i == entries.count - 1 ? " ← most recent" : ""
            return "\(i + 1). \"\(e.transcript)\" → \(e.actions.joined(separator: "; ")) → \(e.outcome)\(mark)"
        }.joined(separator: "\n")
    }

    /// The question the last reply asked ("Do you want me to open Projects?"), so a bare
    /// "yeah" can answer it.
    public var lastQuestion: String? {
        guard let last = entries.last, last.actions == ["say"], last.outcome.hasSuffix("?") else { return nil }
        return last.outcome
    }

    /// What they said that the last question was about, so a short answer ("Claude Code")
    /// completes it (spec §5.4: clarifying questions keep the content).
    public var lastQuestionAbout: String? {
        lastQuestion == nil ? nil : entries.last?.transcript
    }
}
