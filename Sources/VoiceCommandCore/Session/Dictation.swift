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

    public enum End: Equatable, Sendable { case send, done, cancel }

    /// How a segment said while dictating by voice ends it, and the words before that.
    /// "send it" sends, "done" types without sending, "cancel dictation" drops everything.
    /// A bare "send" or "done" counts only as the whole segment, so a sentence that happens
    /// to end in "send" stays content.
    public static func endCommand(in segment: String) -> (content: String, end: End?) {
        let norm = TextMatching.normalized(segment)
        let whole: [String: End] = [
            "send": .send, "send it": .send, "send it now": .send, "send that": .send, "send the message": .send,
            "send this": .send, "send this message": .send,
            "ok send it": .send, "okay send it": .send, "done": .done, "im done": .done, "thats it": .done,
            "stop dictating": .done, "end dictation": .done, "finish": .done, "cancel dictation": .cancel,
            "cancel that": .cancel, "never mind": .cancel,
        ]
        if let end = whole[norm] { return ("", end) }
        let trailing: [(String, End)] = [
            ("[,.]?\\s*(and\\s+|okay\\s+|ok\\s+)?(send it( now)?|send that|send (this|the) message|send this)[.!]?\\s*$", .send),
            ("[,.]?\\s*(stop dictating|end dictation)[.!]?\\s*$", .done),
            ("[,.]?\\s*cancel dictation[.!]?\\s*$", .cancel),
        ]
        for (pattern, end) in trailing {
            if let r = segment.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                return (String(segment[..<r.lowerBound]).trimmingCharacters(in: .whitespaces), end)
            }
        }
        return (segment, nil)
    }

    // MARK: Typing as you go

    /// One step of live typing: what to delete from the end of the typed text, then what to type.
    public struct Mend: Equatable, Sendable {
        /// Characters to backspace first (a period the engine typed itself, mid-sentence).
        public var backspaces: Int
        /// The cleaned segment, with a leading space when something was typed before it.
        public var text: String
        public init(backspaces: Int, text: String) { self.backspaces = backspaces; self.text = text }
    }

    /// The next segment of a run that is typed as you go, given what the run typed so far.
    /// When the run's text ended mid-sentence ("…we need to."), the stray period is
    /// backspaced and the next word lowercased, the same as `join` does all at once:
    /// typing every `mend` in turn gives the text `clean` gives for all the segments.
    public static func mend(typed: String, next segment: String, cleanUp: Bool = true) -> Mend {
        var seg = cleanUp ? clean([segment]) : segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !seg.isEmpty else { return Mend(backspaces: 0, text: "") }
        guard !typed.isEmpty else { return Mend(backspaces: 0, text: seg) }
        var back = 0
        let lastWord = TextMatching.words(typed).last?.norm ?? ""
        // A run ending on a letter lost its period with a trailing filler ("I think um."): also mid-sentence.
        let unfinished = typed.last.map { $0.isLetter || $0.isNumber } ?? false
        if dangling.contains(lastWord) || fillers.contains(lastWord) || unfinished {
            for c in typed.reversed() {
                guard c == "." || c == "," else { break }
                back += 1
            }
            if let first = seg.first, first.isUppercase, !startsWithI(seg) {
                seg = first.lowercased() + seg.dropFirst()
            }
        }
        let separator = typed.last?.isWhitespace == true ? "" : " "
        return Mend(backspaces: back, text: separator + seg)
    }

    // MARK: Recovery

    /// Phrases that fix a wrong guess or bring kept words back, handled on the device
    /// (spec §5.6). Each must be the whole segment, so dictated text that contains the
    /// words ("…and type that instead of the old one") stays content.
    public enum Recovery: Equatable, Sendable {
        /// "That was a command": remove what the run just typed and route those words.
        case wasCommand
        /// "Type that instead": undo the last action if possible and type its words.
        case typeInstead
        /// "Scratch that": remove the last typed chunk; the words go to the history as discarded.
        case scratchThat
        /// "Type it" / "paste it" ("the one about the deck"): type a kept item here.
        case typeKept(about: String?)
        /// "Copy it": put a kept item on the clipboard.
        case copyKept(about: String?)
        /// "What did you keep?": show the Kept list.
        case listKept
    }

    static let recoveryLeading: Set<String> = ["no", "nah", "nope", "oh", "oops", "okay", "ok", "sorry", "wait", "um", "uh", "hey"]

    /// The recovery phrase a whole segment says, if any.
    public static func recovery(in segment: String) -> Recovery? {
        var words = TextMatching.words(segment).map(\.norm)
        while let w = words.first, recoveryLeading.contains(w) { words.removeFirst() }
        if words.last == "please" { words.removeLast() }
        let norm = words.joined(separator: " ")
        guard !norm.isEmpty, words.count <= 9 else { return nil }
        let exact: [String: Recovery] = [
            "that was a command": .wasCommand, "that was a command not dictation": .wasCommand,
            "that was meant as a command": .wasCommand, "thats a command": .wasCommand, "that is a command": .wasCommand,
            "do that instead": .wasCommand, "run that as a command": .wasCommand, "that wasnt dictation": .wasCommand,
            "type that instead": .typeInstead, "type that": .typeInstead, "type it instead": .typeInstead,
            "that was dictation": .typeInstead, "i was dictating": .typeInstead, "that was meant to be typed": .typeInstead,
            "scratch that": .scratchThat, "strike that": .scratchThat, "scratch the last bit": .scratchThat,
            "type it": .typeKept(about: nil), "paste it": .typeKept(about: nil), "type it here": .typeKept(about: nil),
            "paste it here": .typeKept(about: nil), "type what you kept": .typeKept(about: nil),
            "copy it": .copyKept(about: nil), "copy what you kept": .copyKept(about: nil),
            "what did you keep": .listKept, "what have you kept": .listKept, "show me what you kept": .listKept,
            "show what you kept": .listKept, "what did you not type": .listKept,
        ]
        if let r = exact[norm] { return r }
        // "type the last one", "paste the one about the deck", "copy the last one".
        let pattern = "^(type|paste|copy) the (last one|one about (.+)|bit about (.+))$"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: norm, range: NSRange(norm.startIndex..., in: norm)) else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: norm) else { return nil }
            return String(norm[r])
        }
        let about = group(3) ?? group(4)
        return group(1) == "copy" ? .copyKept(about: about) : .typeKept(about: about)
    }

    /// What a cancel phrase does to a run.
    public enum CancelEffect: Equatable, Sendable {
        /// Remove the words (they go to the history as discarded).
        case erase
        /// Stop the run, but keep the words (`.kept(.neverMind)`): "never mind" after a long
        /// dictation is more often about the last sentence than the whole thing.
        case keep
    }

    /// "Cancel dictation" always erases. A softer "never mind" / "cancel that" erases only a
    /// run less than 3 seconds old; an older run's words are kept.
    public static func cancelEffect(of segment: String, runAge: TimeInterval) -> CancelEffect {
        let norm = TextMatching.normalized(segment)
        if norm.hasSuffix("cancel dictation") { return .erase }
        return runAge < neverMindWindow ? .erase : .keep
    }

    public static let neverMindWindow: TimeInterval = 3

    /// Where a segment ending a run with a cancel phrase goes. The bare phrase is a command
    /// that ran; words said before it ("…and the deck is ready, cancel dictation") were never
    /// typed, so they're discarded with the run, or kept when the run's words are kept.
    public static func cancelDisposition(content: String, effect: CancelEffect) -> Disposition {
        guard !TextMatching.words(content).isEmpty else { return .acted }
        return effect == .erase ? .discarded : .kept(.neverMind)
    }

    /// "Type the last one", "copy the one about the deck": names a kept item, so it is never
    /// words to type, whatever is kept.
    public static func namesKeptItem(_ segment: String) -> Bool {
        let norm = TextMatching.normalized(segment)
        return norm.range(of: "(?:^|\\s)(?:type|paste|copy) the (?:last one|one about|bit about)\\b", options: .regularExpression) != nil
    }

    private static func startsWithI(_ s: String) -> Bool {
        s == "I" || s.hasPrefix("I ") || s.hasPrefix("I'") || s.hasPrefix("I’")
    }
}
