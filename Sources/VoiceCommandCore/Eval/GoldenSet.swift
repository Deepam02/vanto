import Foundation

/// Golden-set cases for `router-eval` (M3). Stored as JSON so it can grow from real logs.
public struct GoldenSet: Codable {
    public var fixtures: [String: DesktopSnapshot]
    public var cases: [GoldenCase]

    public static func load(_ url: URL) throws -> GoldenSet {
        let dec = JSONDecoder()
        return try dec.decode(GoldenSet.self, from: Data(contentsOf: url))
    }
}

public struct GoldenCase: Codable {
    public var id: String
    public var transcript: String
    public var fixture: String?
    public var history: [String]?
    public var draft: RouterInputDraft?
    public var pending: String?
    public var lastQuestion: String?
    /// A look_again follow-up turn: what the request already did.
    public var alreadyDone: [String]?
    public var expect: Expectation

    public struct RouterInputDraft: Codable {
        public var app: String
        public var target: String
        public var typedText: String
    }

    public struct Expectation: Codable {
        /// Exact ordered sequence of tool calls.
        public var sequence: [CallMatcher]?
        /// Several right answers: the calls must match one of these sequences exactly.
        public var anyOf: [[CallMatcher]]?
        /// Alternative: every call must match this, at least `minCount` times.
        public var each: CallMatcher?
        public var minCount: Int?
        /// Tools that must not appear.
        public var forbid: [String]?
        /// Safety outcomes from ActionPolicy for the named tools: "run" | "hold" | "reject".
        public var policy: [String: String]?
    }

    public struct CallMatcher: Codable {
        public var tool: String
        public var args: [String: ArgMatcher]?
    }

    /// One argument check. Exactly one field is normally set.
    public struct ArgMatcher: Codable {
        public var eq: JSONValue?          // case-insensitive for strings
        public var oneOf: [JSONValue]?
        public var contains: String?        // case-insensitive substring
        public var words: [String]?        // normalised word equality with any of these
        public var urlHost: String?
        public var absentOr: JSONValue?     // absent, or equal to this
        public var notEq: String?
    }

    public func routerInput(fixtures: [String: DesktopSnapshot]) -> RouterInput {
        let snap = fixtures[fixture ?? "default"] ?? DesktopSnapshot()
        let hist = (history ?? []).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return RouterInput(
            history: hist.isEmpty ? "(no commands yet this session)" : hist,
            snapshot: snap,
            draft: draft.map { RouterInput.Draft(app: $0.app, target: $0.target, typedText: $0.typedText) },
            pending: pending,
            transcript: transcript,
            lastQuestion: lastQuestion,
            alreadyDone: alreadyDone)
    }
}

/// Minimal JSON value for matchers.
public enum JSONValue: Codable, Equatable {
    case string(String), bool(Bool), number(Double), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .null: try c.encodeNil()
        }
    }

    func matches(_ value: Any?) -> Bool {
        switch (self, value) {
        case (.null, nil): return true
        case (.string(let s), let v as String): return s.caseInsensitiveCompare(v) == .orderedSame
        case (.bool(let b), let v as Bool): return b == v
        case (.number(let n), let v as Double): return n == v
        case (.number(let n), let v as Int): return n == Double(v)
        default: return false
        }
    }
}

/// A raw call as returned by the model, before policy rewriting.
public struct RawCall: @unchecked Sendable {
    public let name: String
    public let input: [String: Any]
    public init(name: String, input: [String: Any]) { self.name = name; self.input = input }

    public init(name: String, inputJSON: String) {
        self.name = name
        let data = Data(inputJSON.utf8)
        self.input = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }
}

public enum Grader {
    public struct Verdict {
        public var pass: Bool
        public var reasons: [String]
    }

    static func check(_ m: GoldenCase.ArgMatcher, _ value: Any?) -> String? {
        if let eq = m.eq, !eq.matches(value) { return "expected \(eq), got \(String(describing: value ?? "nil"))" }
        if let one = m.oneOf, !one.contains(where: { $0.matches(value) }) { return "expected one of \(one), got \(String(describing: value ?? "nil"))" }
        if let sub = m.contains {
            guard let v = value as? String, v.lowercased().contains(sub.lowercased()) else { return "expected to contain \"\(sub)\", got \(String(describing: value ?? "nil"))" }
        }
        if let ws = m.words {
            guard let v = value as? String, ws.contains(where: { TextMatching.normalized($0) == TextMatching.normalized(v) }) else {
                return "expected words \(ws), got \(String(describing: value ?? "nil"))"
            }
        }
        if let host = m.urlHost {
            guard let v = value as? String, let h = URL(string: v)?.host?.lowercased(),
                  h == host.lowercased() || h == "www." + host.lowercased() else { return "expected host \(host), got \(String(describing: value ?? "nil"))" }
        }
        if let a = m.absentOr, value != nil, !a.matches(value) { return "expected absent or \(a), got \(String(describing: value!))" }
        if let ne = m.notEq, let v = value as? String, v.caseInsensitiveCompare(ne) == .orderedSame { return "expected not \(ne)" }
        return nil
    }

    static func match(_ matcher: GoldenCase.CallMatcher, _ call: RawCall) -> [String] {
        guard matcher.tool == call.name else { return ["expected \(matcher.tool), got \(call.name)"] }
        var errs: [String] = []
        for (key, m) in matcher.args ?? [:] {
            if let e = check(m, call.input[key]) { errs.append("\(call.name).\(key): \(e)") }
        }
        return errs
    }

    public static func grade(_ c: GoldenCase, calls: [RawCall], fixtures: [String: DesktopSnapshot]) -> Verdict {
        var reasons: [String] = []
        let e = c.expect

        if let seq = e.sequence {
            if seq.count != calls.count {
                reasons.append("expected \(seq.map(\.tool)), got \(calls.map(\.name))")
            } else {
                for (m, call) in zip(seq, calls) { reasons += match(m, call) }
            }
        }
        if let options = e.anyOf {
            let errs = options.map { seq -> [String] in
                guard seq.count == calls.count else { return ["expected \(seq.map(\.tool)), got \(calls.map(\.name))"] }
                return zip(seq, calls).flatMap { match($0, $1) }
            }
            if !errs.contains(where: \.isEmpty) { reasons.append("matched none of \(options.count) answers: " + errs.map { $0.joined(separator: ", ") }.joined(separator: " | ")) }
        }
        if let each = e.each {
            if calls.count < (e.minCount ?? 1) { reasons.append("expected at least \(e.minCount ?? 1) × \(each.tool), got \(calls.count)") }
            for call in calls { reasons += match(each, call) }
        }
        for f in e.forbid ?? [] where calls.contains(where: { $0.name == f }) {
            reasons.append("forbidden tool \(f) was called")
        }

        if let policy = e.policy {
            let parsed = calls.compactMap { try? ToolCall.parse(name: $0.name, input: $0.input) }
            let input = c.routerInput(fixtures: fixtures)
            let ctx = PolicyContext(
                transcript: c.transcript, snapshot: input.snapshot,
                draftOpen: c.draft != nil, draftText: c.draft?.typedText ?? "",
                hasPending: c.pending != nil, pendingSummary: c.pending)
            let decisions = ActionPolicy.evaluate(parsed, context: ctx)
            for (tool, want) in policy {
                guard let idx = parsed.firstIndex(where: { $0.name == tool }) else {
                    reasons.append("policy: no \(tool) call to check"); continue
                }
                let got: String
                switch decisions[idx] { case .run: got = "run"; case .hold: got = "hold"; case .reject(let m): got = "reject (\(m))"; case .skip(let m): got = "skip (\(m))" }
                if !got.hasPrefix(want) { reasons.append("policy for \(tool): expected \(want), got \(got)") }
            }
        }
        return Verdict(pass: reasons.isEmpty, reasons: reasons)
    }
}
