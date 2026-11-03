import Foundation

/// How to reach and drive the composer in known apps (Final review point 12).
/// Defaults are compiled in; an editable copy lives at
/// ~/Library/Application Support/VoiceCommand/AppHints.json and wins when present.
public struct AppHint: Codable, Equatable, Sendable {
    public enum FocusMethod: String, Codable, Sendable {
        /// Press `focusKeys` only if focus isn't already in an editable field (Cursor's Cmd+L toggles).
        case shortcutIfNotFocused
        /// The editable text area nearest the bottom of the window.
        case bottomTextArea
        /// An editable element whose label/placeholder contains `labelContains`.
        case labelled
        /// Terminals: no field, use the terminal tools.
        case terminal
        /// Use whatever is focused (web composers in Chrome).
        case focusedOnly
    }

    public var name: String
    public var bundleIDs: [String]
    public var focus: FocusMethod
    public var focusKeys: String?
    public var labelContains: String?
    public var submitKey: String
    public var newlineKey: String

    public init(name: String, bundleIDs: [String], focus: FocusMethod, focusKeys: String? = nil,
                labelContains: String? = nil, submitKey: String = "return", newlineKey: String = "shift+return") {
        self.name = name; self.bundleIDs = bundleIDs; self.focus = focus; self.focusKeys = focusKeys
        self.labelContains = labelContains; self.submitKey = submitKey; self.newlineKey = newlineKey
    }
}

public struct AppHints: Codable, Equatable, Sendable {
    public var apps: [AppHint]
    /// Apps whose window titles never enter the snapshot (password managers, banking).
    public var privacyDenylist: [String]

    public static let `default` = AppHints(apps: [
        AppHint(name: "Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"], focus: .shortcutIfNotFocused, focusKeys: "cmd+l"),
        AppHint(name: "Claude", bundleIDs: ["com.anthropic.claudefordesktop"], focus: .bottomTextArea),
        AppHint(name: "ChatGPT", bundleIDs: ["com.openai.chat"], focus: .bottomTextArea),
        AppHint(name: "Codex", bundleIDs: ["com.openai.codex"], focus: .bottomTextArea),
        AppHint(name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"], focus: .labelled, labelContains: "message"),
        AppHint(name: "Google Chrome", bundleIDs: ["com.google.Chrome"], focus: .focusedOnly),
        AppHint(name: "Terminal", bundleIDs: ["com.apple.Terminal"], focus: .terminal, newlineKey: "option+return"),
        AppHint(name: "iTerm2", bundleIDs: ["com.googlecode.iterm2"], focus: .terminal),
        AppHint(name: "Ghostty", bundleIDs: ["com.mitchellh.ghostty"], focus: .terminal),
    ], privacyDenylist: [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc", "com.apple.Passwords",
        "com.apple.keychainaccess", "in.sinew.Enpass-Desktop", "com.lastpass.LastPass",
    ])

    public func hint(bundleID: String?) -> AppHint? {
        guard let b = bundleID else { return nil }
        return apps.first { $0.bundleIDs.contains(b) }
    }

    public func hint(named name: String) -> AppHint? {
        let n = name.lowercased()
        return apps.first { $0.name.lowercased() == n }
            ?? apps.first { n.contains($0.name.lowercased()) || $0.name.lowercased().contains(n) }
    }

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceCommand", isDirectory: true)
            .appendingPathComponent("AppHints.json")
    }

    /// Load the editable copy, writing the defaults there on first run.
    public static func loadOrInstall(at url: URL = fileURL) -> AppHints {
        if let data = try? Data(contentsOf: url), let hints = try? JSONDecoder().decode(AppHints.self, from: data) {
            return hints
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(AppHints.default) { try? data.write(to: url) }
        return .default
    }
}
