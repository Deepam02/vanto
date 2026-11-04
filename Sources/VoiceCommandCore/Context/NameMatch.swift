import Foundation

/// How well a spoken name ("zoom out", "the conversations tab") matches a label on screen
/// ("Zoom Out", "Conversations"). Used for menu items, buttons and tabs in any app, so
/// nothing is matched per app. Speech recognition misspells names it doesn't know ("Blue IO"
/// for Blooio, "clawed" for Claude, 4 Nov), so labels that *sound* the same also match.
public enum NameMatch {
    /// Words people add when naming a control that aren't part of its label.
    static let filler: Set<String> = [
        "the", "a", "an", "on", "in", "this", "that", "my", "button", "link", "tab", "page", "menu", "option",
        "section", "part", "item", "click", "press", "go", "to", "open", "please", "called", "named", "one",
    ]

    /// 0…1. 1 is an exact match (ignoring case, punctuation and filler words).
    public static func score(_ query: String, _ label: String) -> Double {
        let q = TextMatching.words(query).map(\.norm).filter { !filler.contains($0) }
        let c = TextMatching.words(label).map(\.norm)
        guard !q.isEmpty, !c.isEmpty else { return 0 }
        if q == c { return 1 }
        // A word matches exactly, as a prefix of 4+ letters ("convo" → "conversations"), or by sound.
        func hit(_ w: String) -> Bool {
            c.contains { $0 == w || (w.count >= 4 && $0.hasPrefix(w)) || ($0.count >= 4 && w.hasPrefix($0)) || soundsAlike(w, $0) }
        }
        let hits = q.filter(hit).count
        if hits == 0 {
            // The whole name heard as different words: "Blue IO" for "Blooio".
            return soundsAlike(q.joined(), c.joined()) ? 0.7 : 0
        }
        let recall = Double(hits) / Double(q.count)
        guard recall >= 0.5 else { return 0 }
        let precision = Double(min(hits, c.count)) / Double(c.count)
        return 0.6 * recall + 0.35 * precision
    }

    /// Index of the best label, if one is good enough and clearly ahead of a different label.
    public static func best(_ query: String, in labels: [String], minimum: Double = 0.55) -> Int? {
        var scored: [(i: Int, s: Double)] = []
        for (i, label) in labels.enumerated() {
            let s = score(query, label)
            if s >= minimum { scored.append((i, s)) }
        }
        scored.sort { a, b in a.s != b.s ? a.s > b.s : a.i < b.i }
        guard let top = scored.first else { return nil }
        let topWords = Set(TextMatching.words(labels[top.i]).map(\.norm))
        // Not a real rival: the same label again (two "Close" items), or nearly the same words
        // ("More options for Competitor website screenshots…" next to the chat itself).
        let rival = scored.dropFirst().first { r in
            let words = Set(TextMatching.words(labels[r.i]).map(\.norm))
            let shared = Double(words.intersection(topWords).count) / Double(max(1, min(words.count, topWords.count)))
            return shared < 0.75
        }
        if let rival, top.s < 1, top.s - rival.s < 0.08 { return nil }
        return top.i
    }

    // MARK: Sound

    /// A rough spoken form: letters that sound alike merged, vowel runs collapsed, so
    /// "blooio" and "blueio" both become "bla", "claude" and "clawed" both "klad".
    public static func phonetic(_ word: String) -> String {
        var s = word.lowercased().filter(\.isLetter)
        for (a, b) in [("ph", "f"), ("ck", "k"), ("qu", "kw"), ("x", "ks"), ("c", "k"), ("q", "k"), ("z", "s"), ("w", "u"), ("y", "i")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        var out = ""
        var lastVowel = false
        for ch in s {
            let vowel = "aeiou".contains(ch)
            if vowel { if !lastVowel { out.append("a") } } else if out.last != ch { out.append(ch) }
            lastVowel = vowel
        }
        if out.count > 3, out.hasSuffix("a") { out.removeLast() }
        return out
    }

    /// Same spoken form, or one sound apart for longer words.
    public static func soundsAlike(_ a: String, _ b: String) -> Bool {
        let pa = phonetic(a), pb = phonetic(b)
        guard pa.count >= 3, pb.count >= 3 else { return false }
        if pa == pb { return true }
        return min(pa.count, pb.count) >= 5 && editDistance(pa, pb) <= 1
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var prev = row[0]
            row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }
}
