import AppKit
import VoiceCommandCore

/// Terminal.app, iTerm2 and Ghostty over their AppleScript dictionaries.
/// Ghostty `input text` and iTerm2 `write text … newline NO` skip the clipboard;
/// Terminal.app has no type-without-run command, so it uses focus plus paste.
@MainActor
enum TerminalAdapter {
    static func q(_ s: String) -> String { AppleScriptRunner.quote(s) }

    static func bundleID(_ app: DesktopSnapshot.TerminalApp) -> String {
        switch app {
        case .terminal: return TerminalSessions.terminalBundleID
        case .iterm2: return TerminalSessions.itermBundleID
        case .ghostty: return TerminalSessions.ghosttyBundleID
        }
    }

    static func appName(_ app: DesktopSnapshot.TerminalApp) -> String {
        switch app { case .terminal: return "Terminal"; case .iterm2: return "iTerm2"; case .ghostty: return "Ghostty" }
    }

    /// AppleScript that binds `target` to the session and then runs `body`.
    static func script(_ s: DesktopSnapshot.TerminalSession, _ body: String) -> String {
        switch s.app {
        case .terminal:
            return """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with target in tabs of w
                        if tty of target is \(q(s.nativeID)) then
                            \(body)
                            return "ok"
                        end if
                    end repeat
                end repeat
                return "missing"
            end tell
            """
        case .iterm2:
            return """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with target in sessions of t
                            if id of target is \(q(s.nativeID)) then
                                \(body)
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
                return "missing"
            end tell
            """
        case .ghostty:
            return """
            tell application id "com.mitchellh.ghostty"
                repeat with target in terminals
                    if ((id of target) as text) is \(q(s.nativeID)) then
                        \(body)
                        return "ok"
                    end if
                end repeat
                return "missing"
            end tell
            """
        }
    }

    static func runBody(_ s: DesktopSnapshot.TerminalSession, _ body: String, timeout: TimeInterval = 1.5) async -> Result<String, AppleScriptRunner.ScriptError> {
        await AppleScriptRunner.shared.runString(script(s, body), timeout: timeout)
    }

    static func focusBody(_ app: DesktopSnapshot.TerminalApp) -> String {
        switch app {
        case .terminal: return "set selected of target to true\n set index of w to 1"
        case .iterm2: return "select w\n tell t to select\n tell target to select"
        case .ghostty: return "focus target"
        }
    }

    static func activate(_ app: DesktopSnapshot.TerminalApp) async -> Bool {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID(app)).first else { return false }
        return await AppWindowAdapter.refocus(pid: running.processIdentifier)
    }

    static func focus(_ s: DesktopSnapshot.TerminalSession) async -> ExecOutcome {
        let previous = AppWindowAdapter.frontmostPID()
        let r = await runBody(s, focusBody(s.app))
        guard case .success(let out) = r, out == "ok" else { return .fail(fail(r, s, "Couldn't find that terminal session")) }
        guard await activate(s.app) else { return .fail("\(appName(s.app)) didn't come to the front") }
        return .ok("\(appName(s.app)): \(DesktopSnapshot.clipTitle(s.title))", undo: previous.map { .refocus(pid: $0) })
    }

    static func newTab(app: DesktopSnapshot.TerminalApp, cwd: String?) async -> ExecOutcome {
        let dir = cwd.map { ($0 as NSString).expandingTildeInPath }
        switch app {
        case .ghostty:
            let src = """
            tell application id "com.mitchellh.ghostty"
                set cfg to new surface configuration
                \(dir.map { "set initial working directory of cfg to \(q($0))" } ?? "")
                if (count of windows) is 0 then
                    new window with configuration cfg
                else
                    new tab in front window with configuration cfg
                end if
                return "ok"
            end tell
            """
            let r = await AppleScriptRunner.shared.runString(src, timeout: 1.5)
            guard case .success = r else { return .fail(fail(r, nil, "Couldn't open a Ghostty tab")) }
        case .iterm2:
            let cd = dir.map { "tell current session of current tab of current window to write text \(q("cd " + shellQuote($0)))" } ?? ""
            let src = """
            tell application id "com.googlecode.iterm2"
                if (count of windows) is 0 then
                    create window with default profile
                else
                    tell current window to create tab with default profile
                end if
                \(cd)
                return "ok"
            end tell
            """
            let r = await AppleScriptRunner.shared.runString(src, timeout: 1.5)
            guard case .success = r else { return .fail(fail(r, nil, "Couldn't open an iTerm2 tab")) }
        case .terminal:
            // No AppleScript verb for a new tab: activate and press ⌘T.
            if !TerminalSessions.running(TerminalSessions.terminalBundleID) {
                _ = await AppWindowAdapter.openApp("com.apple.Terminal", snapshot: DesktopSnapshot())
            } else {
                _ = await activate(.terminal)
                _ = KeyPresser.press("cmd+t")
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if let dir {
                let src = """
                tell application id "com.apple.Terminal" to do script \(q("cd " + shellQuote(dir))) in selected tab of front window
                """
                _ = await AppleScriptRunner.shared.runString(src, timeout: 1.5)
            }
        }
        _ = await activate(app)
        return .ok("New \(appName(app)) tab", undo: nil)
    }

    /// Type text into a session without running it.
    static func type(_ s: DesktopSnapshot.TerminalSession, _ text: String) async -> ExecOutcome {
        let clean = text.replacingOccurrences(of: "[\\r\\n]+$", with: "", options: .regularExpression)
        switch s.app {
        case .ghostty:
            let r = await runBody(s, "input text \(q(clean)) to target")
            guard case .success(let o) = r, o == "ok" else { return .fail(fail(r, s, "Couldn't type into Ghostty")) }
            _ = await runBody(s, focusBody(.ghostty)); _ = await activate(.ghostty)
        case .iterm2:
            let r = await runBody(s, "tell target to write text \(q(clean)) newline NO")
            guard case .success(let o) = r, o == "ok" else { return .fail(fail(r, s, "Couldn't type into iTerm2")) }
            _ = await runBody(s, focusBody(.iterm2)); _ = await activate(.iterm2)
        case .terminal:
            let f = await focus(s)
            guard case .ok = f else { return f }
            await PasteService.paste(clean)
        }
        return .ok("Typed into \(appName(s.app))", undo: nil)
    }

    /// Run a command (type + Enter) in a session, then show it.
    static func run(_ s: DesktopSnapshot.TerminalSession, _ command: String) async -> ExecOutcome {
        let r: Result<String, AppleScriptRunner.ScriptError>
        switch s.app {
        case .terminal: r = await runBody(s, "do script \(q(command)) in target")
        case .iterm2: r = await runBody(s, "tell target to write text \(q(command))")
        case .ghostty: r = await runBody(s, "input text \(q(command)) to target\n send key \"enter\" to target")
        }
        guard case .success(let o) = r, o == "ok" else { return .fail(fail(r, s, "Couldn't run that in \(appName(s.app))")) }
        _ = await runBody(s, focusBody(s.app))
        _ = await activate(s.app)
        return .ok("Ran: \(command)", undo: nil)
    }

    /// Press Enter in the session (submit a typed prompt). The caller has refocused it.
    static func pressEnter(_ s: DesktopSnapshot.TerminalSession) async -> Bool {
        switch s.app {
        case .ghostty:
            if case .success("ok") = await runBody(s, "send key \"enter\" to target") { return true }
            return KeyPresser.press("return")
        case .iterm2:
            if case .success("ok") = await runBody(s, "tell target to write text \"\"") { return true }
            return KeyPresser.press("return")
        case .terminal:
            return KeyPresser.press("return")
        }
    }

    /// Is this session the one in front right now?
    static func isFront(_ s: DesktopSnapshot.TerminalSession) async -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID(s.app) else { return false }
        let sessions = await TerminalSessions.all()
        return sessions.first { $0.id == s.id }?.selected ?? false
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func fail<T>(_ r: Result<T, AppleScriptRunner.ScriptError>, _ s: DesktopSnapshot.TerminalSession?, _ fallback: String) -> String {
        if case .failure(let e) = r, e.isPermissionDenied {
            return "Allow VoiceCommand to control \(s.map { appName($0.app) } ?? "the terminal") in System Settings › Privacy › Automation"
        }
        if case .success("missing") = r as? Result<String, AppleScriptRunner.ScriptError> { return "That terminal session is gone" }
        return fallback
    }
}
