import Foundation

/// One transcript buffer per session with a "consumed" cursor (Final review point 3).
///
/// Speech arrives as segments (one per voice-activity run). Segments before the cursor
/// have been acted on; segments after it form the latest utterance the router sees.
public struct TranscriptBuffer: Sendable {
    public struct Segment: Equatable, Sendable {
        public let id: Int
        public var text: String
        public let endedAt: Date
        /// What speech recognition heard before vocabulary boosting, when boosting changed it.
        public var raw: String?
    }

    public private(set) var segments: [Segment] = []
    /// Index of the first unconsumed segment.
    public private(set) var cursor: Int = 0
    private var nextID = 0
    /// Unconsumed speech older than this is dropped. Long enough for a thinking pause in
    /// the middle of a dictated prompt.
    public var maxUnconsumedAge: TimeInterval = 120

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

    /// The text after the cursor, segments joined by single spaces.
    public var latest: String {
        segments[cursor...].map(\.text).joined(separator: " ")
    }

    /// `latest` as heard before vocabulary boosting, or nil when boosting changed nothing.
    public var latestRaw: String? {
        let pending = segments[cursor...]
        guard pending.contains(where: { $0.raw != nil }) else { return nil }
        return pending.map { $0.raw ?? $0.text }.joined(separator: " ")
    }

    public var latestSegmentIDs: [Int] { segments[cursor...].map(\.id) }

    public var hasUnconsumed: Bool { cursor < segments.count }

    /// Move the cursor past every segment a router reply covered (actions ran or `ignore`).
    /// `wait_for_more` never calls this.
    public mutating func consume(through segmentID: Int) {
        guard let idx = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        cursor = max(cursor, idx + 1)
    }

    public mutating func consumeAll() { cursor = segments.count }

    /// Drop unconsumed segments that ended more than `maxUnconsumedAge` ago.
    /// Returns true if anything was dropped.
    @discardableResult
    public mutating func dropStale(now: Date = Date()) -> Bool {
        var dropped = false
        while cursor < segments.count, now.timeIntervalSince(segments[cursor].endedAt) > maxUnconsumedAge {
            cursor += 1
            dropped = true
        }
        return dropped
    }

    public mutating func reset() {
        segments.removeAll()
        cursor = 0
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
}
