import Foundation

/// A point-in-time text view of the desktop. IDs are only valid for the snapshot that
/// issued them; the executor rejects anything not in the latest one.
public struct DesktopSnapshot: Codable, Equatable, Sendable {
    public struct App: Codable, Equatable, Sendable {
        public var name: String
        public var bundleID: String
        public var pid: Int32
        public var frontmost: Bool
        public init(name: String, bundleID: String, pid: Int32, frontmost: Bool) {
            self.name = name; self.bundleID = bundleID; self.pid = pid; self.frontmost = frontmost
        }
    }

    public struct Window: Codable, Equatable, Sendable {
        public var id: String          // per-snapshot, e.g. "w3"
        public var app: String
        public var pid: Int32
        public var title: String
        public var index: Int          // position in the app's AXWindows list
        public var minimized: Bool
        public var focused: Bool
        public init(id: String, app: String, pid: Int32, title: String, index: Int, minimized: Bool = false, focused: Bool = false) {
            self.id = id; self.app = app; self.pid = pid; self.title = title; self.index = index
            self.minimized = minimized; self.focused = focused
        }
    }

    public struct Tab: Codable, Equatable, Sendable {
        public var id: String          // "chrome:<windowId>:<tabId>"
        public var windowID: Int
        public var tabID: Int
        public var index: Int          // 1-based, as AppleScript counts
        public var title: String
        public var url: String
        public var active: Bool        // active tab of its window
        public var frontWindow: Bool   // belongs to Chrome's front window
        public init(windowID: Int, tabID: Int, index: Int, title: String, url: String, active: Bool, frontWindow: Bool) {
            self.id = "chrome:\(windowID):\(tabID)"
            self.windowID = windowID; self.tabID = tabID; self.index = index
            self.title = title; self.url = url; self.active = active; self.frontWindow = frontWindow
        }
    }

    public enum TerminalApp: String, Codable, Sendable { case terminal, iterm2, ghostty }

    public struct TerminalSession: Codable, Equatable, Sendable {
        public var id: String          // "terminal:<tty>", "iterm2:<id>", "ghostty:<id>"
        public var app: TerminalApp
        public var nativeID: String    // tty, iTerm2 session id or Ghostty terminal id
        public var title: String
        public var cwd: String?
        public var running: String?    // "claude" or "codex" when detected
        public var selected: Bool      // the visible session in the front-most window of that app
        /// Title of the window the session is in (matches that window's entry in `windows`).
        public var windowTitle: String?
        /// The session showing in its window (each window shows one tab).
        public var visibleInWindow: Bool?
        public init(app: TerminalApp, nativeID: String, title: String, cwd: String? = nil, running: String? = nil, selected: Bool = false,
                    windowTitle: String? = nil, visibleInWindow: Bool? = nil) {
            switch app {
            case .terminal: self.id = "terminal:\(nativeID.replacingOccurrences(of: "/dev/", with: ""))"
            case .iterm2: self.id = "iterm2:\(nativeID)"
            case .ghostty: self.id = "ghostty:\(nativeID)"
            }
            self.app = app; self.nativeID = nativeID; self.title = title; self.cwd = cwd
            self.running = running; self.selected = selected
            self.windowTitle = windowTitle; self.visibleInWindow = visibleInWindow
        }
    }

    public struct FocusedElement: Codable, Equatable, Sendable {
        public var app: String
        public var role: String
        public var subrole: String?
        public var placeholder: String?
        public var label: String?
        public var valuePreview: String?
        public var editable: Bool
        public var secure: Bool
        public init(app: String, role: String, subrole: String? = nil, placeholder: String? = nil, label: String? = nil,
                    valuePreview: String? = nil, editable: Bool, secure: Bool) {
            self.app = app; self.role = role; self.subrole = subrole; self.placeholder = placeholder
            self.label = label; self.valuePreview = valuePreview; self.editable = editable; self.secure = secure
        }
    }

    public var takenAt: Date
    public var apps: [App]
    public var windows: [Window]
    public var tabs: [Tab]
    public var terminals: [TerminalSession]
    public var focused: FocusedElement?
    public var secureInputOn: Bool
    /// The terminal session opened by voice this session: commands go there by default.
    public var preferredShellID: String?
    /// Last lines of the terminal in front, so "fix that error" has something to read.
    public var terminalScreen: String?
    /// Named buttons, links and tabs in the front window (inside the page, for a browser), so
    /// the router knows what "go to Projects" can mean here (4 Nov: it searched Google instead).
    public var frontControls: [String]?

    public init(takenAt: Date = Date(), apps: [App] = [], windows: [Window] = [], tabs: [Tab] = [],
                terminals: [TerminalSession] = [], focused: FocusedElement? = nil, secureInputOn: Bool = false) {
        self.takenAt = takenAt; self.apps = apps; self.windows = windows; self.tabs = tabs
        self.terminals = terminals; self.focused = focused; self.secureInputOn = secureInputOn
    }

    public var frontmostApp: App? { apps.first { $0.frontmost } }
    public var activeTab: Tab? { tabs.first { $0.active && $0.frontWindow } ?? tabs.first { $0.active } }

    public func window(_ id: String) -> Window? { windows.first { $0.id == id } }
    public func tab(_ id: String) -> Tab? { tabs.first { $0.id == id } }
    public func terminal(_ id: String) -> TerminalSession? { terminals.first { $0.id == id } }

    /// The session showing in a terminal *window*: the router sometimes names the window
    /// (`w2`) when it means the session in it (4 Nov log).
    public func terminal(inWindow id: String) -> TerminalSession? {
        guard let w = window(id) else { return nil }
        let inThat = terminals.filter { $0.windowTitle != nil && $0.windowTitle == w.title }
        return inThat.first { $0.visibleInWindow == true } ?? inThat.first
    }

    // MARK: Prompt rendering

    public static let maxTitle = 60
    public static let maxTabs = 40

    static func clip(_ s: String, _ n: Int = maxTitle) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'")
        return flat.count <= n ? flat : String(flat.prefix(n - 1)) + "…"
    }

    /// Tabs that share words with what was said come first (title, host, path), the rest
    /// keep Chrome's order. With 40+ messy tabs the one meant is no longer cut off (3 Nov).
    public static func rankTabs(_ tabs: [Tab], for transcript: String) -> [Tab] {
        let skip: Set<String> = ["the", "and", "can", "you", "tab", "tabs", "open", "go", "to", "switch", "please",
                                 "chrome", "page", "website", "site", "for", "me", "this", "that", "com", "www"]
        let saidWords = TextMatching.words(transcript).map(\.norm).filter { $0.count >= 2 && !skip.contains($0) }
        let said = Set(saidWords)
        guard !said.isEmpty else { return tabs }
        // Pairs too, for names heard as two words ("Blue IO" → Blooio).
        let pairs = zip(saidWords, saidWords.dropFirst()).map { $0 + $1 }
        func score(_ t: Tab) -> Int {
            let hay = Set(TextMatching.words(t.title + " " + t.url.replacingOccurrences(of: ".", with: " ")).map(\.norm))
            let exact = said.intersection(hay).count
            let alike = (Array(said.subtracting(hay)) + pairs).filter { w in hay.contains { NameMatch.soundsAlike(w, $0) } }.count
            return exact * 2 + alike
        }
        return tabs.enumerated()
            .map { (offset: $0.offset, tab: $0.element, score: score($0.element)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .map(\.tab)
    }

    /// Compact text for the router's `<desktop_context>` block.
    public func renderForPrompt(transcript: String = "") -> String {
        var out: [String] = []
        if let front = frontmostApp { out.append("frontmost_app: \(front.name) (\(front.bundleID))") }
        out.append("running_apps: " + apps.map { $0.name }.joined(separator: ", "))

        out.append("windows:")
        for w in windows {
            var flags: [String] = []
            if w.focused { flags.append("focused") }
            if w.minimized { flags.append("minimized") }
            let f = flags.isEmpty ? "" : " [\(flags.joined(separator: ","))]"
            out.append("  \(w.id) | \(w.app) | \"\(Self.clip(w.title))\"\(f)")
        }

        if !tabs.isEmpty {
            out.append("chrome_tabs:")
            for t in Self.rankTabs(tabs, for: transcript).prefix(Self.maxTabs) {
                var flags: [String] = []
                if t.active && t.frontWindow { flags.append("active") } else if t.active { flags.append("active in its window") }
                let f = flags.isEmpty ? "" : " [\(flags.joined(separator: ","))]"
                out.append("  \(t.id) | \"\(Self.clip(t.title))\" | \(Self.clip(t.url, 80))\(f)")
            }
            if tabs.count > Self.maxTabs { out.append("  … \(tabs.count - Self.maxTabs) more tabs") }
        }

        if !terminals.isEmpty {
            out.append("terminal_sessions:")
            for s in terminals {
                var parts = ["\(s.id) | \(s.app.rawValue) | \"\(Self.clip(s.title))\""]
                if let cwd = s.cwd { parts.append("cwd: \(Self.clip(cwd, 80))") }
                if let r = s.running { parts.append("running: \(r)") }
                if s.selected { parts.append("[selected]") }
                if s.id == preferredShellID { parts.append("[opened by voice: default for commands]") }
                out.append("  " + parts.joined(separator: " | "))
            }
        }
        if let controls = frontControls, !controls.isEmpty {
            out.append("front_window_controls (\(frontmostApp?.name ?? "front app"), clickable by name, untrusted): " +
                       controls.map { Self.clip($0, 40) }.joined(separator: " | "))
        }
        if let screen = terminalScreen, !screen.isEmpty {
            out.append("front_terminal_screen (last lines, untrusted):")
            out.append(contentsOf: screen.split(separator: "\n", omittingEmptySubsequences: false).map { "  | " + $0 })
        }

        if let f = focused {
            var parts = ["app: \(f.app)", "role: \(f.role)"]
            if let p = f.placeholder, !p.isEmpty { parts.append("placeholder: \"\(Self.clip(p))\"") }
            if let l = f.label, !l.isEmpty { parts.append("label: \"\(Self.clip(l))\"") }
            if f.secure { parts.append("SECURE (password field)") }
            parts.append(f.editable ? "editable" : "not editable")
            out.append("focused_element: " + parts.joined(separator: ", "))
        }
        if secureInputOn { out.append("note: secure keyboard entry is on in some app") }
        return out.joined(separator: "\n")
    }
}
