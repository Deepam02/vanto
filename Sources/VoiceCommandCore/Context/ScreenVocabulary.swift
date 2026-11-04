import Foundation

/// Words for the speech model to listen for, beyond its built-in list (FluidAudio custom
/// vocabulary): the person's own dictionary, and names on screen right now. On 4 Nov
/// "Blooio" was heard as "Blue Yo" while a tab called "Blooio" was open.
public enum ScreenVocabulary {
    /// The Settings dictionary: one entry per line, `Word` or `Word: how I say it, another way`.
    public static func parseDictionary(_ text: String) -> [(String, [String])] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let word = parts.first, !word.isEmpty, !word.hasPrefix("#") else { return nil }
            let aliases = parts.count > 1
                ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : []
            return (word, aliases)
        }
    }

    /// Words that are already well known, or too generic to be worth boosting.
    static let common: Set<String> = [
        "home", "inbox", "overview", "settings", "dashboard", "new", "tab", "google", "chrome", "untitled", "search",
        "results", "page", "login", "sign", "welcome", "docs", "documentation", "pull", "request", "issues", "feed",
        "notifications", "messages", "profile", "account", "billing", "the", "and", "with", "from", "your", "for",
        "this", "that", "about", "help", "terminal", "window", "file", "edit", "view", "zsh", "bash",
    ]

    /// Distinctive names from tab titles, window titles and terminal folders: brand-like
    /// words (an inner capital, a dot, a capitalised word that isn't common). At most `limit`.
    public static func terms(from snap: DesktopSnapshot, limit: Int = 40) -> [String] {
        var texts: [String] = []
        for t in snap.tabs {
            // The page or site name is the first part of a title ("Overview | Context.dev").
            texts.append(contentsOf: t.title.components(separatedBy: CharacterSet(charactersIn: "|·—–-")).prefix(2))
        }
        texts += snap.windows.map(\.title)
        texts += snap.terminals.compactMap { $0.cwd.map { ($0 as NSString).lastPathComponent } }
        var seen = Set<String>()
        var out: [String] = []
        for text in texts {
            for raw in text.split(whereSeparator: { $0.isWhitespace || "()[]{}\"'“”,:;!?/".contains($0) }) {
                let word = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
                guard word.count >= 4, word.count <= 30, !common.contains(word.lowercased()),
                      word.contains(where: \.isLetter), seen.insert(word.lowercased()).inserted else { continue }
                let innerCapital = word.dropFirst().contains(where: \.isUppercase)
                let dotted = word.contains(".") && !word.hasSuffix(".")
                let named = word.first?.isUppercase == true
                if innerCapital || dotted || named || word.contains("-") { out.append(word) }
                if out.count >= limit { return out }
            }
        }
        return out
    }
}
