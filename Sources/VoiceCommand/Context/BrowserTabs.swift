import AppKit
import VoiceCommandCore

/// Chrome tabs over Chrome's AppleScript dictionary. IDs are Chrome's own stable window
/// and tab IDs: "chrome:<windowId>:<tabId>". Safari is cut from the MVP (Final review 9).
enum BrowserTabs {
    static let chromeBundleID = "com.google.Chrome"

    static var chromeRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleID).isEmpty
    }

    // Bulk property reads (3 Apple events per window) keep 40+ tabs fast.
    static let listScript = """
    set US to ASCII character 31
    set RS to ASCII character 30
    tell application id "com.google.Chrome"
        set out to ""
        if (count of windows) is 0 then return ""
        set fw to id of front window
        repeat with w in windows
            set wid to id of w
            set ati to active tab index of w
            set ids to id of every tab of w
            set titles to title of every tab of w
            set urls to URL of every tab of w
            repeat with i from 1 to count of ids
                set out to out & wid & US & (item i of ids) & US & i & US & (i = ati) & US & (wid = fw) & US & (item i of titles) & US & (item i of urls) & RS
            end repeat
        end repeat
        return out
    end tell
    """

    /// Last good list, used when a refresh times out (with no tabs the router opens duplicates).
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var last: (at: Date, tabs: [DesktopSnapshot.Tab])?
        func put(_ t: [DesktopSnapshot.Tab]) { lock.withLock { last = (Date(), t) } }
        func get() -> [DesktopSnapshot.Tab] { lock.withLock { last.flatMap { Date().timeIntervalSince($0.at) < 60 ? $0.tabs : nil } ?? [] } }
    }
    private static let cache = Cache()

    static func chromeTabs(denied: Set<String>) async -> [DesktopSnapshot.Tab] {
        guard chromeRunning, !denied.contains(chromeBundleID) else { return [] }
        guard case .success(let text) = await AppleScriptRunner.shared.runString(listScript, timeout: 1.5) else { return cache.get() }
        let tabs = parse(text)
        cache.put(tabs)
        return tabs
    }

    static func parse(_ text: String) -> [DesktopSnapshot.Tab] {
        text.split(separator: "\u{1E}").compactMap { rec in
            let f = rec.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7, let wid = Int(f[0]), let tid = Int(f[1]), let idx = Int(f[2]) else { return nil }
            return DesktopSnapshot.Tab(windowID: wid, tabID: tid, index: idx, title: f[5], url: f[6],
                                       active: f[3] == "true", frontWindow: f[4] == "true")
        }
    }
}
