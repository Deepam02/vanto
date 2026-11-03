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
                set out to out & (tty of t) & US & ttl & US & ((selected of t) and (wid = fw)) & RS
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
                    set out to out & (id of s) & US & (name of s) & US & (tty of s) & US & p & US & (isCurTab and ((id of s) = curSess) and ((id of w) = cwid)) & RS
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

    static func all() async -> [DesktopSnapshot.TerminalSession] {
        var out: [DesktopSnapshot.TerminalSession] = []
        let ttyCommands = running(terminalBundleID) || running(itermBundleID) ? processesByTTY() : [:]

        if running(terminalBundleID), case .success(let text) = await AppleScriptRunner.shared.runString(terminalScript) {
            for f in records(text) where f.count >= 3 {
                let tty = f[0]
                out.append(.init(app: .terminal, nativeID: tty, title: f[1], cwd: nil,
                                 running: agent(commands: ttyCommands[ttyName(tty)], title: f[1]), selected: f[2] == "true"))
            }
        }
        if running(itermBundleID), case .success(let text) = await AppleScriptRunner.shared.runString(itermScript) {
            for f in records(text) where f.count >= 5 {
                out.append(.init(app: .iterm2, nativeID: f[0], title: f[1], cwd: f[3].isEmpty ? nil : f[3],
                                 running: agent(commands: ttyCommands[ttyName(f[2])], title: f[1]), selected: f[4] == "true"))
            }
        }
        if running(ghosttyBundleID), case .success(let text) = await AppleScriptRunner.shared.runString(ghosttyScript) {
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
