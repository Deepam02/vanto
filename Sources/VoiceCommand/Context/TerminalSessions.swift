import AppKit
import VoiceCommandCore

/// Terminal sessions from Terminal.app, iTerm2 and Ghostty AppleScript dictionaries.
/// IDs: Terminal.app tab tty, iTerm2 session id, Ghostty terminal id (Final review 6).
/// Sessions running `claude` or `codex` are marked so "ask Claude Code…" has a target.
enum TerminalSessions {
    static let terminalBundleID = "com.apple.Terminal"
    static let itermBundleID = "com.googlecode.iterm2"
    static let ghosttyBundleID = "com.mitchellh.ghostty"

    static func running(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static let terminalScript = """
    set US to ASCII character 31
    set RS to ASCII character 30
    tell application id "com.apple.Terminal"
        set out to ""
        if (count of windows) is 0 then return ""
        set fw to id of front window
        repeat with w in windows
            set wid to id of w
            set wname to name of w
            repeat with t in tabs of w
                set ttl to custom title of t
                if ttl is "" or ttl is missing value then set ttl to wname
                set out to out & (tty of t) & US & ttl & US & ((selected of t) and (wid = fw)) & US & wname & US & (selected of t) & RS
            end repeat
        end repeat
        return out
    end tell
    """

    static let itermScript = """
    set US to ASCII character 31
    set RS to ASCII character 30
    tell application id "com.googlecode.iterm2"
        set out to ""
        if (count of windows) is 0 then return ""
        set cwid to id of current window
        repeat with w in windows
            set curTab to current tab of w
            repeat with t in tabs of w
                set curSess to id of current session of t
                set isCurTab to (index of t) = (index of curTab)
                repeat with s in sessions of t
                    set p to ""
                    try
                        tell s to set p to variable named "session.path"
                    end try
                    set out to out & (id of s) & US & (name of s) & US & (tty of s) & US & p & US & (isCurTab and ((id of s) = curSess) and ((id of w) = cwid)) & US & (name of w) & US & (isCurTab and ((id of s) = curSess)) & RS
                end repeat
            end repeat
        end repeat
        return out
    end tell
    """

    static let ghosttyScript = """
    set US to ASCII character 31
    set RS to ASCII character 30
    tell application id "com.mitchellh.ghostty"
        set out to ""
        if (count of windows) is 0 then return ""
        set fwid to id of front window
        repeat with w in windows
            repeat with t in tabs of w
                set focusedID to ""
                try
                    set focusedID to id of focused terminal of t
                end try
                repeat with term in terminals of t
                    set wd to ""
                    try
                        set wd to working directory of term
                    end try
                    set out to out & (id of term) & US & (name of term) & US & wd & US & ((selected of t) and ((id of w) = fwid) and ((id of term) = focusedID)) & RS
                end repeat
            end repeat
        end repeat
        return out
    end tell
    """

    /// The last list each app returned, used when a refresh times out: a busy Terminal (Claude
    /// Code redrawing) missed the old 0.5 s limit and every command saw "No terminal session
    /// open" (3–4 Nov).
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var lists: [DesktopSnapshot.TerminalApp: (at: Date, sessions: [DesktopSnapshot.TerminalSession])] = [:]
        func put(_ app: DesktopSnapshot.TerminalApp, _ s: [DesktopSnapshot.TerminalSession]) { lock.withLock { lists[app] = (Date(), s) } }
        func get(_ app: DesktopSnapshot.TerminalApp, maxAge: TimeInterval = 120) -> [DesktopSnapshot.TerminalSession] {
            lock.withLock { lists[app].flatMap { Date().timeIntervalSince($0.at) < maxAge ? $0.sessions : nil } ?? [] }
        }
    }
    private static let cache = Cache()
    static let listTimeout: TimeInterval = 2

    static func all() async -> [DesktopSnapshot.TerminalSession] {
        var out: [DesktopSnapshot.TerminalSession] = []
        let ttyCommands = running(terminalBundleID) || running(itermBundleID) ? processesByTTY() : [:]

        if running(terminalBundleID) {
            if case .success(let text) = await AppleScriptRunner.shared.runString(terminalScript, timeout: listTimeout) {
                var list: [DesktopSnapshot.TerminalSession] = []
                for f in records(text) where f.count >= 3 {
                    let tty = f[0]
                    list.append(.init(app: .terminal, nativeID: tty, title: f[1], cwd: nil,
                                      running: agent(commands: ttyCommands[ttyName(tty)], title: f[1]), selected: f[2] == "true",
                                      windowTitle: f.count >= 5 ? f[3] : nil, visibleInWindow: f.count >= 5 ? f[4] == "true" : nil))
                }
                cache.put(.terminal, list)
                out += list
            } else {
                out += cache.get(.terminal)
            }
        }
        if running(itermBundleID) {
            if case .success(let text) = await AppleScriptRunner.shared.runString(itermScript, timeout: listTimeout) {
                var list: [DesktopSnapshot.TerminalSession] = []
                for f in records(text) where f.count >= 5 {
                    list.append(.init(app: .iterm2, nativeID: f[0], title: f[1], cwd: f[3].isEmpty ? nil : f[3],
                                      running: agent(commands: ttyCommands[ttyName(f[2])], title: f[1]), selected: f[4] == "true",
                                      windowTitle: f.count >= 7 ? f[5] : nil, visibleInWindow: f.count >= 7 ? f[6] == "true" : nil))
                }
                cache.put(.iterm2, list)
                out += list
            } else {
                out += cache.get(.iterm2)
            }
        }
        if running(ghosttyBundleID), case .success(let text) = await AppleScriptRunner.shared.runString(ghosttyScript, timeout: listTimeout) {
            for f in records(text) where f.count >= 4 {
                out.append(.init(app: .ghostty, nativeID: f[0], title: f[1], cwd: f[2].isEmpty ? nil : f[2],
                                 running: agent(commands: nil, title: f[1]), selected: f[3] == "true"))
            }
        }
        // Only the front-most terminal app's selected session stays [selected].
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            let frontApp: DesktopSnapshot.TerminalApp? = [terminalBundleID: .terminal, itermBundleID: .iterm2, ghosttyBundleID: .ghostty][front]
            if let frontApp, out.contains(where: { $0.app == frontApp && $0.selected }) {
                for i in out.indices where out[i].app != frontApp { out[i].selected = false }
            }
        }
        return out
    }

    /// The last lines of the session in front, if a terminal is the front app, with obvious
    /// secrets masked. Lets "fix that error" and "run it again" see the screen.
    static func frontScreen(_ sessions: [DesktopSnapshot.TerminalSession]) async -> String? {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return nil }
        let src: String
        switch front {
        case terminalBundleID:
            src = "tell application id \"com.apple.Terminal\" to return contents of selected tab of front window"
        case itermBundleID:
            src = "tell application id \"com.googlecode.iterm2\" to return contents of current session of current window"
        default:
            return nil
        }
        guard case .success(let text) = await AppleScriptRunner.shared.runString(src, timeout: 1) else { return nil }
        return lastLines(text)
    }

    static func lastLines(_ text: String, count: Int = 25, maxChars: Int = 2000) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0.prefix(160)).trimmingCharacters(in: .whitespaces) }
        let kept = Array(lines.reversed().drop { $0.isEmpty }.prefix(count).reversed())
        guard !kept.isEmpty else { return nil }
        var out = redact(kept.joined(separator: "\n"))
        if out.count > maxChars { out = String(out.suffix(maxChars)) }
        return out
    }

    /// API keys, tokens and passwords on screen never go to the router.
    static func redact(_ text: String) -> String {
        let patterns = [
            "sk-[A-Za-z0-9_\\-]{12,}", "gh[pousr]_[A-Za-z0-9]{20,}", "AKIA[0-9A-Z]{16}", "xox[abpr]-[A-Za-z0-9-]{10,}",
            "(?i)(password|passwd|secret|token|api[_-]?key)\\s*[=:]\\s*\\S+",
        ]
        return patterns.reduce(text) { $0.replacingOccurrences(of: $1, with: "[hidden]", options: .regularExpression) }
    }

    static func records(_ text: String) -> [[String]] {
        text.split(separator: "\u{1E}").map { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init) }
    }

    static func ttyName(_ tty: String) -> String { tty.replacingOccurrences(of: "/dev/", with: "") }

    /// "claude" or "codex" if one is running in the session.
    static func agent(commands: [String]?, title: String) -> String? {
        for c in commands ?? [] {
            let base = (c as NSString).lastPathComponent.lowercased()
            if base == "claude" || base.hasPrefix("claude-") { return "claude" }
            if base == "codex" { return "codex" }
        }
        let t = title.lowercased()
        if t.contains("claude") || title.hasPrefix("✳") { return "claude" }
        if t.contains("codex") { return "codex" }
        return nil
    }

    /// tty name → command names, from one `ps` call.
    static func processesByTTY() -> [String: [String]] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-A", "-o", "tty=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var map: [String: [String]] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] != "??" else { continue }
            map[parts[0], default: []].append(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return map
    }
}
