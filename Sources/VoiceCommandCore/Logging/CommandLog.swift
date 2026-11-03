import Foundation

/// One JSONL line per routed command (M7). Times are epoch seconds; durations derive from them.
public struct CommandRecord: Codable, Sendable {
    public var kind = "command"
    public var id: String
    public var sessionID: String
    public var generation: Int
    public var transcript: String
    public var liveTranscript: String?
    public var pauseMs: Int?
    // Timeline
    public var speechEndAt: Double?
    public var transcriptFinalAt: Double?
    public var requestSentAt: Double?
    public var firstToolAt: Double?
    public var actionDoneAt: Double?
    // What happened
    public var tools: [String] = []
    public var decisions: [String] = []
    public var results: [String] = []
    public var outcome: String = ""          // ok | failed | pending | waiting | ignored | error | cancelled
    public var error: String?
    public var irreversible: Bool = false    // a submit or terminal command actually ran
    public var mismatchNotes: [String] = []
    public var usage: Usage?
    public var retried: Bool = false

    public init(id: String = UUID().uuidString, sessionID: String, generation: Int, transcript: String) {
        self.id = id; self.sessionID = sessionID; self.generation = generation; self.transcript = transcript
    }

    public var latencyMs: Int? {
        guard let s = speechEndAt, let d = actionDoneAt else { return nil }
        return Int(((d - s) * 1000).rounded())
    }
    public var timeToFirstToolMs: Int? {
        guard let s = requestSentAt, let f = firstToolAt else { return nil }
        return Int(((f - s) * 1000).rounded())
    }
}

/// A later correction of an earlier command: undo, a spoken correction, or a cancelled pending.
public struct CorrectionRecord: Codable, Sendable {
    public var kind = "correction"
    public var commandID: String
    public var sessionID: String
    public var how: String          // undo | correction | cancel_pending
    public var at: Double
    public init(commandID: String, sessionID: String, how: String, at: Date = Date()) {
        self.commandID = commandID; self.sessionID = sessionID; self.how = how; self.at = at.timeIntervalSince1970
    }
}

public struct SessionRecord: Codable, Sendable {
    public var kind = "session"
    public var sessionID: String
    public var startedAt: Double
    public var endedAt: Double
    public var endReason: String
    public init(sessionID: String, startedAt: Date, endedAt: Date, endReason: String) {
        self.sessionID = sessionID; self.startedAt = startedAt.timeIntervalSince1970
        self.endedAt = endedAt.timeIntervalSince1970; self.endReason = endReason
    }
}

public final class CommandLog: @unchecked Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoiceCommand", isDirectory: true)
            .appendingPathComponent("commands.jsonl")
    }

    public let url: URL
    private let queue = DispatchQueue(label: "VoiceCommand.CommandLog")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public init(url: URL = CommandLog.defaultURL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    public func append<T: Encodable>(_ record: T) {
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0A)
        queue.async { [url] in
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    public func flush() { queue.sync {} }
}
