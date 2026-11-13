import Foundation

/// How a dictation run types its words (owner's decision, 13 Nov; spec §10).
///
/// Live typing shows progress on a long prompt; one paste after a pause is cleaner where a
/// half-written message shouldn't sit in the box (a chat someone may be watching), and is
/// the safer choice whenever the call to dictate wasn't certain.
public enum TypingMode: String, Codable, Equatable, Sendable {
    /// Each segment is typed as it's heard, mid-sentence pauses mended (`Dictation.mend`).
    case live
    /// Segments are collected and pasted once, cleaned, when speech pauses.
    case onPause = "on_pause"
    /// Hold Fn: everything is pasted once when the key is released.
    case onRelease = "on_release"

    /// What kind of place the text is going into.
    public enum Surface: String, Codable, Equatable, Sendable {
        /// Coding and AI assistants: Claude Code or Codex in a terminal, Claude, ChatGPT, Cursor.
        case assistant
        /// Long-form editors: Notes, Docs, Notion, text and code editors.
        case longForm = "long_form"
        /// Message boxes: Slack, Messages, WhatsApp, Mail and Gmail, X, LinkedIn, Discord, Teams.
        case message
        /// Anything else.
        case other
    }

    /// Who decided this was dictation.
    public enum Source: String, Codable, Equatable, Sendable {
        /// Hold Fn: always dictation.
        case holdFn = "hold_fn"
        /// The local intent gate was certain (explicit start, or certain dictation).
        case local
        /// The router decided: a guess, so nothing is typed until speech pauses.
        case router
    }

    /// The policy. Live only for long prompts and long-form writing that the device was sure
    /// about with nothing playing; one paste on a pause everywhere else.
    public static func choose(surface: Surface, source: Source, mediaPlaying: Bool) -> TypingMode {
        if source == .holdFn { return .onRelease }
        if source == .router || mediaPlaying { return .onPause }
        switch surface {
        case .assistant, .longForm: return .live
        case .message, .other: return .onPause
        }
    }

    // MARK: Surfaces

    static let assistantBundles: Set<String> = [
        "com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex", "com.todesktop.230313mzl4w4u92",
    ]
    static let longFormBundles: Set<String> = [
        "com.apple.Notes", "com.apple.TextEdit", "com.apple.iWork.Pages", "com.microsoft.Word", "notion.id",
        "md.obsidian", "net.shinyfrog.bear", "com.lukilabs.lukiapp", "com.microsoft.VSCode", "dev.zed.Zed",
        "com.sublimetext.4", "com.apple.dt.Xcode", "com.google.Chrome.app.docs",
    ]
    static let messageBundles: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
        "com.apple.mail", "com.microsoft.Outlook", "com.hnc.Discord", "com.microsoft.teams", "com.microsoft.teams2",
        "ru.keepcoder.Telegram", "com.readdle.smartemail-Mac", "com.superhuman.electron", "com.linkedin.LinkedIn",
    ]
    /// Web apps, by host (the address bar of the tab in front).
    static let assistantHosts = ["claude.ai", "chatgpt.com", "chat.openai.com", "gemini.google.com", "perplexity.ai", "cursor.com"]
    static let longFormHosts = ["docs.google.com", "notion.so", "notion.site", "coda.io", "dropbox.com/paper", "quip.com"]
    static let messageHosts = [
        "mail.google.com", "x.com", "twitter.com", "linkedin.com", "discord.com", "teams.microsoft.com", "teams.live.com",
        "web.whatsapp.com", "app.slack.com", "outlook.live.com", "outlook.office.com", "messages.google.com", "web.telegram.org",
    ]
    /// By app name, when the bundle isn't known (a renamed or newer build).
    static let assistantNames = ["claude", "chatgpt", "codex", "cursor"]
    static let longFormNames = ["notes", "textedit", "pages", "word", "notion", "obsidian", "bear", "craft", "visual studio code", "zed"]
    static let messageNames = ["slack", "messages", "whatsapp", "mail", "outlook", "discord", "teams", "telegram", "linkedin", "spark", "superhuman"]

    /// Where the focused field is. `terminalProgram` is what the terminal in front is running
    /// ("claude", "codex"); `url` is the active browser tab's address.
    public static func surface(app: String?, bundleID: String? = nil, url: String? = nil, terminalProgram: String? = nil) -> Surface {
        if let p = terminalProgram?.lowercased(), p == "claude" || p == "codex" { return .assistant }
        if let host = url.flatMap(Self.hostAndPath) {
            func matches(_ list: [String]) -> Bool {
                list.contains { host == $0 || host.hasPrefix($0 + "/") || host.hasSuffix("." + $0) || host.contains("." + $0 + "/") }
            }
            if matches(assistantHosts) { return .assistant }
            if matches(longFormHosts) { return .longForm }
            if matches(messageHosts) { return .message }
        }
        if let b = bundleID {
            if assistantBundles.contains(b) { return .assistant }
            if longFormBundles.contains(b) { return .longForm }
            if messageBundles.contains(b) { return .message }
        }
        if let name = app?.lowercased() {
            if assistantNames.contains(where: { name == $0 || name.hasPrefix($0 + " ") }) { return .assistant }
            if longFormNames.contains(name) { return .longForm }
            if messageNames.contains(name) { return .message }
        }
        return .other
    }

    /// "https://www.notion.so/team/page" → "notion.so/team/page".
    static func hostAndPath(_ url: String) -> String? {
        var s = url.lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        return s.isEmpty ? nil : s
    }
}
