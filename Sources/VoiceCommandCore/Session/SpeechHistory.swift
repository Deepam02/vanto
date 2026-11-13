import Foundation

/// Local speech history: everything said in a session and where it ended up (acted, typed,
/// kept, discarded), one JSON line each in
/// ~/Library/Application Support/VoiceCommand/history.jsonl. Never sent anywhere.
///
/// No expiry and no cap (Deepam, 13 Nov: "tools I use keep my dictation from three months
/// ago; space doesn't matter"); cleared from Settings. The "Kept" list is the kept and
/// discarded entries. Reads stay fast on a large file: only the tail is read at start, and
/// recent entries are kept in memory as they're appended.
public final class SpeechHistory: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var at: Double
        public var text: String
        public var disposition: Disposition
        public var sessionID: String?
        /// The app it was typed into, or in front when it was said.
        public var app: String?
        /// What speech recognition heard before vocabulary boosting, when that differed.
        public var raw: String?

        public init(id: String = UUID().uuidString, at: Date = Date(), text: String, disposition: Disposition,
                    sessionID: String? = nil, app: String? = nil, raw: String? = nil) {
            self.id = id; self.at = at.timeIntervalSince1970; self.text = text; self.disposition = disposition
            self.sessionID = sessionID; self.app = app; self.raw = raw
        }

        public var date: Date { Date(timeIntervalSince1970: at) }
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceCommand", isDirectory: true)
            .appendingPathComponent("history.jsonl")
    }

    public let url: URL
    /// How many of the newest entries (of any kind) stay in memory.
    public let recentLimit: Int
    /// How many of the newest kept entries stay in memory, even when older than `recentLimit`.
    public let keptLimit: Int

    private let lock = NSLock()
    private var recentEntries: [Entry] = []     // oldest first
    private var recentKept: [Entry] = []        // oldest first
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public init(url: URL = SpeechHistory.defaultURL, recentLimit: Int = 500, keptLimit: Int = 100) {
        self.url = url
        self.recentLimit = recentLimit
        self.keptLimit = keptLimit
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        loadTail()
    }

    // MARK: Writing

    public func append(_ entry: Entry) { append([entry]) }

    public func append(_ entries: [Entry]) {
        let entries = entries.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !entries.isEmpty else { return }
        var data = Data()
        for e in entries {
            guard let line = try? encoder.encode(e) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        lock.lock()
        defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
        for e in entries { remember(e) }
    }

    /// The buffer's dispositions, as history entries.
    public func append(_ disposed: [TranscriptBuffer.Disposed], sessionID: String?, app: String? = nil) {
        append(disposed.map {
            Entry(at: $0.at, text: $0.text, disposition: $0.disposition, sessionID: sessionID, app: app, raw: $0.raw)
        })
    }

    /// Settings → "Clear speech history".
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
        recentEntries.removeAll()
        recentKept.removeAll()
    }

    // MARK: Reading

    /// The newest entries of any kind, newest first.
    public func recent(limit: Int = 50) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(recentEntries.suffix(limit).reversed())
    }

    /// The Kept list: kept and discarded words, newest first (the menu shows 10).
    public func kept(limit: Int = 10) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(recentKept.suffix(limit).reversed())
    }

    /// The newest kept words: what "type it" and "copy it" mean.
    public var lastKept: Entry? { kept(limit: 1).first }

    /// The newest kept entry that best matches what was said ("the one about the deck").
    /// Recent kept words are searched first, then the whole file.
    public func kept(matching query: String) -> Entry? {
        let wanted = Self.contentWords(query)
        guard !wanted.isEmpty else { return lastKept }
        let recent = Self.best(in: kept(limit: keptLimit), for: wanted)
        if let r = recent, r.hits == wanted.count { return r.entry }
        let older = Self.best(in: all().filter { $0.disposition.isKept }.reversed(), for: wanted)
        return (older.map { $0.hits > (recent?.hits ?? 0) } ?? false ? older : recent)?.entry
    }

    /// Every entry in the file, oldest first. Reads the whole file: not for hot paths.
    public func all() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return [] }
        return Self.decodeLines(data)
    }

    // MARK: Private

    private func remember(_ e: Entry) {
        recentEntries.append(e)
        if recentEntries.count > recentLimit { recentEntries.removeFirst(recentEntries.count - recentLimit) }
        if e.disposition.isKept {
            recentKept.append(e)
            if recentKept.count > keptLimit { recentKept.removeFirst(recentKept.count - keptLimit) }
        }
    }

    /// Read backwards from the end in chunks until there are enough recent and kept entries,
    /// so a months-long history doesn't slow the app's start.
    private func loadTail() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return }
        let chunk: UInt64 = 256 * 1024
        var offset = size
        var tail = Data()
        var entries: [Entry] = []
        while offset > 0 {
            let start = offset > chunk ? offset - chunk : 0
            try? handle.seek(toOffset: start)
            let piece = (try? handle.read(upToCount: Int(offset - start))) ?? Data()
            tail = piece + tail
            offset = start
            // Decode only whole lines; a partial first line waits for the next chunk.
            var usable = tail
            if offset > 0, let nl = tail.firstIndex(of: 0x0A) { usable = tail[tail.index(after: nl)...] }
            entries = Self.decodeLines(Data(usable))
            let keptCount = entries.lazy.filter { $0.disposition.isKept }.count
            if entries.count >= recentLimit && keptCount >= keptLimit { break }
        }
        for e in entries { remember(e) }
    }

    static func decodeLines(_ data: Data) -> [Entry] {
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
    }

    static let stopWords: Set<String> = [
        "the", "a", "an", "one", "about", "that", "this", "it", "last", "thing", "bit", "with", "of", "on", "to", "i", "said",
    ]

    static func contentWords(_ text: String) -> Set<String> {
        Set(TextMatching.words(text).map(\.norm).filter { !stopWords.contains($0) })
    }

    /// The first entry (callers pass newest first) with the most query words, at least half.
    static func best<S: Sequence>(in entries: S, for wanted: Set<String>) -> (entry: Entry, hits: Int)? where S.Element == Entry {
        var best: (Entry, Int)?
        for e in entries {
            let have = contentWords(e.text)
            let hits = wanted.reduce(0) { n, w in
                n + (have.contains(w) || have.contains(where: { $0.hasPrefix(w) && w.count >= 4 }) ? 1 : 0)
            }
            guard hits * 2 >= wanted.count, hits > 0 else { continue }
            if best == nil || hits > best!.1 { best = (e, hits) }
        }
        return best.map { ($0.0, $0.1) }
    }
}
