import Foundation

/// Word-level matching between what the router returned and what the person said.
public enum TextMatching {
    public struct Word: Equatable {
        public let norm: String
        public let range: Range<String.Index>
    }

    /// Lowercased alphanumeric words with their ranges in the original string.
    /// Apostrophes are dropped inside words ("don't" → "dont"); other punctuation splits.
    public static func words(_ text: String) -> [Word] {
        var out: [Word] = []
        var start: String.Index?
        var buf = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c.isLetter || c.isNumber {
                if start == nil { start = i }
                buf.append(contentsOf: c.lowercased())
            } else if (c == "'" || c == "’") && start != nil {
                // keep the word going, drop the apostrophe
            } else if let s = start {
                out.append(Word(norm: buf, range: s..<i))
                start = nil
                buf = ""
            }
            i = text.index(after: i)
        }
        if let s = start { out.append(Word(norm: buf, range: s..<text.endIndex)) }
        return out
    }

    public static func normalized(_ text: String) -> String {
        words(text).map(\.norm).joined(separator: " ")
    }

    /// Index of the last contiguous occurrence of `needle` in `hay` (word sequences).
    static func lastOccurrence(_ needle: [String], in hay: [String]) -> Int? {
        guard !needle.isEmpty, needle.count <= hay.count else { return nil }
        var i = hay.count - needle.count
        while i >= 0 {
            if Array(hay[i..<i + needle.count]) == needle { return i }
            i -= 1
        }
        return nil
    }

    public struct SpanMatch: Equatable {
        /// The exact substring of the transcript to type.
        public let text: String
        /// Word indices [start, end) in the transcript.
        public let wordStart: Int
        public let wordEnd: Int
        /// True when the payload matched word for word after normalisation.
        public let exact: Bool
    }

    /// Find the transcript span that `payload` was copied from.
    ///
    /// Exact match after normalising case, spacing and punctuation returns the transcript's
    /// own text for that span. Otherwise the best aligned window is returned if at least
    /// `minOverlap` of the payload's words appear in order; nil means refuse to type.
    public static func transcriptSpan(for payload: String, in transcript: String, minOverlap: Double = 0.6) -> SpanMatch? {
        let tw = words(transcript)
        let pw = words(payload).map(\.norm)
        guard !pw.isEmpty, !tw.isEmpty else { return nil }
        let tn = tw.map(\.norm)

        if let i = lastOccurrence(pw, in: tn) {
            let range = tw[i].range.lowerBound..<tw[i + pw.count - 1].range.upperBound
            return SpanMatch(text: String(transcript[range]), wordStart: i, wordEnd: i + pw.count, exact: true)
        }

        // Fuzzy: longest common subsequence aligned window.
        let n = tn.count, m = pw.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for a in 1...n { for b in 1...m {
            dp[a][b] = tn[a - 1] == pw[b - 1] ? dp[a - 1][b - 1] + 1 : max(dp[a - 1][b], dp[a][b - 1])
        } }
        let common = dp[n][m]
        guard Double(common) / Double(m) >= minOverlap else { return nil }
        // Backtrack to find matched transcript indices.
        var a = n, b = m
        var matched: [Int] = []
        while a > 0 && b > 0 {
            if tn[a - 1] == pw[b - 1] { matched.append(a - 1); a -= 1; b -= 1 }
            else if dp[a - 1][b] >= dp[a][b - 1] { a -= 1 } else { b -= 1 }
        }
        guard let lo = matched.min(), let hi = matched.max() else { return nil }
        // Reject spans much longer than the payload (matched words scattered far apart).
        guard Double(hi - lo + 1) <= Double(m) * 1.5 + 2 else { return nil }
        let range = tw[lo].range.lowerBound..<tw[hi].range.upperBound
        return SpanMatch(text: String(transcript[range]), wordStart: lo, wordEnd: hi + 1, exact: false)
    }

    /// Word index where `phrase` occurs last in `transcript`, or nil.
    public static func lastWordIndex(of phrase: String, in transcript: String) -> Int? {
        lastOccurrence(words(phrase).map(\.norm), in: words(transcript).map(\.norm))
    }

    public static func contains(_ transcript: String, anyOf phrases: [String]) -> Bool {
        let tn = words(transcript).map(\.norm)
        return phrases.contains { lastOccurrence(words($0).map(\.norm), in: tn) != nil }
    }
}

/// Spoken symbols for terminal commands and code-like spans (Final review point 14).
public enum SpokenSymbols {
    /// Multi-word phrases first so "dash dash" wins over "dash".
    static let phrases: [(spoken: [String], symbol: String)] = [
        (["dash", "dash"], "--"), (["double", "dash"], "--"), (["minus", "minus"], "--"),
        (["at", "sign"], "@"), (["forward", "slash"], "/"), (["back", "slash"], "\\"),
        (["dash"], "-"), (["hyphen"], "-"), (["minus"], "-"),
        (["dot"], "."), (["period"], "."), (["slash"], "/"), (["tilde"], "~"),
        (["underscore"], "_"), (["pipe"], "|"), (["star"], "*"), (["asterisk"], "*"),
        (["equals"], "="), (["colon"], ":"), (["ampersand"], "&"), (["dollar"], "$"),
        (["hash"], "#"), (["caret"], "^"), (["percent"], "%"),
    ]
    /// Symbols glued to the next token ("--" "watch" → "--watch").
    static let prefixGlue: Set<String> = ["-", "--", "~", "$", "#"]
    /// Symbols glued on both sides ("index" "." "js" → "index.js").
    static let bothGlue: Set<String> = [".", "/", "_", ":", "@", "=", "\\"]

    /// "npm run dash dash watch" → "npm run --watch"; "cd tilde slash code" → "cd ~/code".
    public static func apply(_ text: String) -> String {
        let raw = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var tokens: [String] = []
        var i = 0
        outer: while i < raw.count {
            for (spoken, symbol) in phrases where i + spoken.count <= raw.count {
                let slice = raw[i..<i + spoken.count].map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
                if slice == spoken {
                    tokens.append(symbol)
                    i += spoken.count
                    continue outer
                }
            }
            tokens.append(raw[i])
            i += 1
        }
        var out = ""
        var glueNext = false
        for t in tokens {
            let isBoth = bothGlue.contains(t)
            if out.isEmpty || glueNext || isBoth {
                out += t
            } else {
                out += " " + t
            }
            glueNext = isBoth || prefixGlue.contains(t)
        }
        return out
    }

    /// Normalised command words for comparing a command against the transcript.
    /// Keeps symbol characters as part of tokens; strips sentence punctuation the ASR adds.
    public static func commandTokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { tok -> String in
                var s = String(tok)
                while let last = s.last, ",;!?\"'".contains(last) { s.removeLast() }
                // A sentence period after a word ("test.", "--force.") is ASR punctuation;
                // "." alone or inside a token ("index.js", "../") is part of the command.
                let body = s.dropLast()
                if s.count > 1, s.last == ".", let prev = body.last, prev.isLetter || prev.isNumber, !body.contains(".") {
                    s.removeLast()
                }
                while let first = s.first, "\"'".contains(first) { s.removeFirst() }
                return s
            }
            .filter { !$0.isEmpty }
    }

    /// True if `command` was dictated word for word in `transcript` (after symbol mapping).
    public static func isDictated(_ command: String, in transcript: String) -> Bool {
        let c = commandTokens(command)
        guard !c.isEmpty else { return false }
        for candidate in [transcript, apply(transcript)] {
            let t = commandTokens(candidate)
            if TextMatching.lastOccurrence(c, in: t) != nil { return true }
        }
        return false
    }
}
