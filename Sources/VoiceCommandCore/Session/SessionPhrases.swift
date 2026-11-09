import Foundation

/// Phrases handled on the device, with no router call.
public enum SessionPhrases {
    /// Explicit ways to end the session. Only these: "I'm done" and "that's all" can end a
    /// dictated sentence, so the router decides those.
    static let endPhrases: Set<String> = [
        "end the session", "end session", "end this session", "close the session", "close session",
        "close this session", "stop the session", "stop session", "stop this session", "end the voice session",
        "stop listening", "coke the session",
    ]
    /// Words that may come before the phrase in the same clause ("okay, end the session").
    static let leading: Set<String> = [
        "uh", "um", "umm", "er", "ah", "okay", "ok", "so", "and", "now", "please", "just", "you", "can", "could",
        "hey", "alright", "right", "then", "nah", "no",
    ]

    /// True when the last clause of the transcript is an explicit request to end the
    /// session. Earlier words don't block it: "Henderson. Uh End the session." went to
    /// wait_for_more on 9 Nov, and the person had to use the hotkey.
    public static func endsSession(_ transcript: String) -> Bool {
        let clauses = transcript.split(whereSeparator: { ".!?;\n".contains($0) })
        guard let last = clauses.last(where: { !TextMatching.words(String($0)).isEmpty }) else { return false }
        var words = TextMatching.words(String(last)).map(\.norm)
        if words.last == "please" || words.last == "now" { words.removeLast() }
        // The phrase must end the clause, after nothing but filler and politeness.
        for start in words.indices {
            let phrase = words[start...].joined(separator: " ")
            if endPhrases.contains(phrase) {
                return words[..<start].allSatisfy { leading.contains($0) || Dictation.fillers.contains($0) }
            }
        }
        return false
    }
}
