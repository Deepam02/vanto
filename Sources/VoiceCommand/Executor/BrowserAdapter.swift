import AppKit
import VoiceCommandCore

/// Chrome actions over AppleScript ("Allow JavaScript from Apple Events" stays off).
@MainActor
enum BrowserAdapter {
    static let chrome = "tell application id \"com.google.Chrome\""

    static func q(_ s: String) -> String { AppleScriptRunner.quote(s) }

    /// The active tab of Chrome's front window, as (windowID, tabID).
    static func activeTab() async -> (Int, Int)? {
        let src = """
        \(chrome)
            if (count of windows) is 0 then return ""
            return ((id of front window) as text) & "," & ((id of active tab of front window) as text)
        end tell
        """
        guard case .success(let s) = await AppleScriptRunner.shared.runString(src, timeout: 1), !s.isEmpty else { return nil }
        let parts = s.split(separator: ",").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    static func activateChrome() async {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: BrowserTabs.chromeBundleID).first {
            _ = await AppWindowAdapter.refocus(pid: app.processIdentifier)
        }
    }

    static func switchTab(_ tab: DesktopSnapshot.Tab) async -> ExecOutcome {
        let previous = await activeTab()
        let src = """
        \(chrome)
            set w to window id \(tab.windowID)
            set i to 0
            repeat with t in tabs of w
                set i to i + 1
                if id of t is \(tab.tabID) then exit repeat
            end repeat
            set active tab index of w to i
            set index of w to 1
            return ((id of active tab of w) as text)
        end tell
        """
        let r = await AppleScriptRunner.shared.runString(src, timeout: 1.5)
        await activateChrome()
        guard case .success(let active) = r, active == String(tab.tabID) else {
            return .fail(errorText(r, fallback: "Couldn't switch to that tab"))
        }
        return .ok("Tab: \(DesktopSnapshot.clipTitle(tab.title))", undo: previous.map { .chromeTab(windowID: $0.0, tabID: $0.1) })
    }

    static func switchTo(windowID: Int, tabID: Int) async -> Bool {
        let tab = DesktopSnapshot.Tab(windowID: windowID, tabID: tabID, index: 0, title: "", url: "", active: false, frontWindow: false)
        if case .ok = await switchTab(tab) { return true }
        return false
    }

    static func openURL(_ url: String, newTab: Bool) async -> ExecOutcome {
        if !BrowserTabs.chromeRunning {
            // Launch Chrome straight to the URL.
            guard let u = URL(string: url), let chromeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: BrowserTabs.chromeBundleID) else {
                return .fail("Chrome isn't installed")
            }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            _ = try? await NSWorkspace.shared.open([u], withApplicationAt: chromeURL, configuration: cfg)
            return .ok("Opened \(URL(string: url)?.host ?? url)", undo: nil)
        }
        let previous = await activeTab()
        let src: String
        if newTab {
            src = """
            \(chrome)
                if (count of windows) is 0 then make new window
                set w to front window
                set t to make new tab at end of tabs of w with properties {URL:\(q(url))}
                set index of w to 1
                return ((id of w) as text) & "," & ((id of t) as text)
            end tell
            """
        } else {
            src = """
            \(chrome)
                if (count of windows) is 0 then make new window
                set w to front window
                set URL of active tab of w to \(q(url))
                return ((id of w) as text) & "," & ((id of active tab of w) as text)
            end tell
            """
        }
        let r = await AppleScriptRunner.shared.runString(src, timeout: 1.5)
        await activateChrome()
        guard case .success(let ids) = r else { return .fail(errorText(r, fallback: "Couldn't open that page")) }
        let parts = ids.split(separator: ",").compactMap { Int($0) }
        let host = URL(string: url)?.host ?? url
        if newTab, parts.count == 2 {
            return .ok("Opened \(host)", undo: .closeChromeTab(windowID: parts[0], tabID: parts[1], thenShow: previous))
        }
        return .ok("Opened \(host)", undo: nil)
    }

    static func newTab() async -> ExecOutcome {
        let src = """
        \(chrome)
            if (count of windows) is 0 then make new window
            set w to front window
            set t to make new tab at end of tabs of w
            set index of w to 1
            return ((id of w) as text) & "," & ((id of t) as text)
        end tell
        """
        let previous = await activeTab()
        let r = await AppleScriptRunner.shared.runString(src, timeout: 1.5)
        await activateChrome()
        guard case .success(let ids) = r else { return .fail(errorText(r, fallback: "Couldn't open a new tab")) }
        let parts = ids.split(separator: ",").compactMap { Int($0) }
        return .ok("New tab", undo: parts.count == 2 ? .closeChromeTab(windowID: parts[0], tabID: parts[1], thenShow: previous) : nil)
    }

    static func closeTab(_ tab: DesktopSnapshot.Tab) async -> ExecOutcome {
        let src = """
        \(chrome)
            set w to window id \(tab.windowID)
            close (first tab of w whose id is \(tab.tabID))
            return "ok"
        end tell
        """
        let r = await AppleScriptRunner.shared.runString(src, timeout: 1.5)
        guard case .success = r else { return .fail(errorText(r, fallback: "Couldn't close that tab")) }
        return .ok("Closed \(DesktopSnapshot.clipTitle(tab.title))", undo: .reopenURL(tab.url))
    }

    static func navigate(_ action: NavigateAction) async -> ExecOutcome {
        let verb: String
        switch action { case .reload: verb = "reload"; case .back: verb = "go back"; case .forward: verb = "go forward" }
        let src = """
        \(chrome)
            if (count of windows) is 0 then return "none"
            tell active tab of front window to \(verb)
            return "ok"
        end tell
        """
        let r = await AppleScriptRunner.shared.runString(src, timeout: 1)
        guard case .success(let s) = r, s == "ok" else { return .fail(errorText(r, fallback: "No Chrome tab to \(verb)")) }
        let label = ["reload": "Reloaded", "go back": "Back", "go forward": "Forward"][verb] ?? verb
        return .ok(label, undo: nil)
    }

    static func search(_ query: String) async -> ExecOutcome {
        var comps = URLComponents(string: "https://www.google.com/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        let outcome = await openURL(comps.url!.absoluteString, newTab: true)
        if case .ok(_, let undo) = outcome { return .ok("Searching: \(query)", undo: undo) }
        return outcome
    }

    static func errorText<T>(_ r: Result<T, AppleScriptRunner.ScriptError>, fallback: String) -> String {
        if case .failure(let e) = r {
            if e.isPermissionDenied { return "Allow VoiceCommand to control Chrome in System Settings › Privacy › Automation" }
            if e.number == AppleScriptRunner.ScriptError.timeout.number { return "Chrome didn't answer in time" }
        }
        return fallback
    }
}
