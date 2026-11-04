import Foundation

/// Hold-Fn dictation text: speech segments joined into what gets typed.
///
/// Segments split wherever the person paused, and the transcriber ends each one like a
/// sentence ("we need to." / "Improve the screens."). Joining undoes that when the pause
/// came after a word that can't end a sentence. `clean` also drops filler words; it never
/// rewrites or reorders content words.
public enum Dictation {
    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "hmm", "mm", "mhm"]
    /// Words a sentence doesn't end on: a pause after one is mid-sentence.
    static let dangling: Set<String> = [
        "and", "so", "then", "or", "but", "because", "like", "the", "a", "an", "to", "of", "for",
        "with", "in", "on", "at", "my", "your", "our", "their", "we", "i", "is", "are", "was", "that",
    ]

    /// Segments joined as spoken, mid-sentence pauses mended.
    public static func join(_ segments: [String]) -> String {
        var out = ""
        for raw in segments {
            var seg = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !seg.isEmpty else { continue }
            if out.isEmpty { out = seg; continue }
            let lastWord = TextMatching.words(out).last?.norm ?? ""
            if dangling.contains(lastWord) || fillers.contains(lastWord) {
                // "we need to." + "Improve…" → "we need to improve…"
                while let c = out.last, c == "." || c == "," { out.removeLast() }
                if let first = seg.first, first.isUppercase, !startsWithI(seg) {
                    seg = first.lowercased() + seg.dropFirst()
                }
            }
            out += " " + seg
        }
        return out
    }

    /// `join`, then filler words removed and spacing and capitals tidied.
    public static func clean(_ segments: [String]) -> String {
        let joined = join(segments)
        let pattern = "\\b(" + fillers.sorted().joined(separator: "|") + ")\\b[,.]?\\s*"
        var text = joined.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+([,.!?])", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "([,.!?])[,.]+", with: "$1", options: .regularExpression)
        text = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",")))
        // Capitalise the start of each sentence (a filler may have been the first word).
        var result = ""
        var capNext = true
        for c in text {
            if capNext, c.isLetter { result += c.uppercased(); capNext = false; continue }
            if c == "." || c == "!" || c == "?" { capNext = true } else if !c.isWhitespace { capNext = false }
            result.append(c)
        }
        return result
    }

    private static func startsWithI(_ s: String) -> Bool {
        s == "I" || s.hasPrefix("I ") || s.hasPrefix("I'") || s.hasPrefix("I’")
    }
}
