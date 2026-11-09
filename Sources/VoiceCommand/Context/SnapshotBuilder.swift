import AppKit
import Carbon.HIToolbox
import VoiceCommandCore

/// Builds the desktop snapshot the router sees and keeps the live handles the executor
/// needs (window elements by per-snapshot ID). Event-driven: refreshed on app switches while
/// a session is open, and right before every router call. Only the debug window polls (1 s),
/// so tab switches inside Chrome show up there within a second (M2).
@MainActor
final class SnapshotBuilder: ObservableObject {
    @Published private(set) var snapshot = DesktopSnapshot()
    @Published private(set) var lastBuildMs = 0
    /// Window ID → AX element, for the latest snapshot only.
    private(set) var windowElements: [String: AXUIElement] = [:]

    var hints: AppHints
    /// The terminal session opened by voice this session (commands go there by default).
    var preferredShellID: String?
    /// Chrome tabs that were active, newest first, as seen at each refresh.
    private var recentTabIDs: [String] = []
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var inflight: Task<DesktopSnapshot, Never>?
    /// Something ran since the last snapshot, so the screen may have changed.
    private var dirty = true
    private var consumers = 0
    private var pollers = 0

    init(hints: AppHints) {
        self.hints = hints
    }

    /// Start live refresh. Balanced by `endLive(poll:)`; the session and the debug window
    /// each hold one. `poll` adds a 1 s timer for as long as any poller is live.
    func beginLive(poll: Bool = false) {
        consumers += 1
        if poll {
            pollers += 1
            if pollers == 1 {
                timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    Task { @MainActor in await self?.refresh() }
                }
            }
        }
        guard consumers == 1 else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func endLive(poll: Bool = false) {
        if poll {
            pollers = max(0, pollers - 1)
            if pollers == 0 { timer?.invalidate(); timer = nil }
        }
        consumers = max(0, consumers - 1)
        guard consumers == 0 else { return }
        if let o = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        activationObserver = nil
    }

    /// Rebuild now. Concurrent calls coalesce into the one already running.
    @discardableResult
    func refresh() async -> DesktopSnapshot {
        if let t = inflight { return await t.value }
        let t = Task { await build() }
        inflight = t
        let snap = await t.value
        inflight = nil
        dirty = false
        return snap
    }

    /// Start reading the screen now (when speech starts), so it's ready when routing begins.
    func prefetch() {
        guard inflight == nil else { return }
        Task { _ = await refresh() }
    }

    /// A snapshot taken after `since` with nothing run since, or a fresh one. Reading the
    /// screen took ~0.5 s per command on 4 Nov; prefetched during speech it's usually free.
    func current(since: Date) async -> DesktopSnapshot {
        if let t = inflight { return await t.value }
        if !dirty, snapshot.takenAt >= since { return snapshot }
        return await refresh()
    }

    func markDirty() { dirty = true }

    private func build() async -> DesktopSnapshot {
        let t0 = Date()

        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        let front = NSWorkspace.shared.frontmostApplication
        let apps = running.map {
            DesktopSnapshot.App(name: $0.localizedName ?? $0.bundleIdentifier ?? "?", bundleID: $0.bundleIdentifier ?? "",
                                pid: $0.processIdentifier, frontmost: $0.processIdentifier == front?.processIdentifier)
        }

        // Windows via Accessibility (no CGWindowList, no Screen Recording).
        let denied = Set(hints.privacyDenylist)
        var windows: [DesktopSnapshot.Window] = []
        var elements: [String: AXUIElement] = [:]
        // Frontmost app first so its windows get the lowest IDs.
        let isFront: (NSRunningApplication) -> Bool = { $0.processIdentifier == front?.processIdentifier }
        let ordered = running.filter(isFront) + running.filter { !isFront($0) }
        for app in ordered {
            let axApp = AX.app(app.processIdentifier)
            let focusedWin = isFront(app) ? AX.element(axApp, kAXFocusedWindowAttribute) : nil
            for (i, w) in AX.elements(axApp, kAXWindowsAttribute).enumerated() {
                let role = AX.string(w, kAXSubroleAttribute)
                if role == "AXSystemDialog" || role == "AXFloatingWindow" { continue }
                let id = "w\(windows.count + 1)"
                var title = AX.string(w, kAXTitleAttribute) ?? ""
                if denied.contains(app.bundleIdentifier ?? "") { title = "(hidden for privacy)" }
                windows.append(.init(id: id, app: app.localizedName ?? "?", pid: app.processIdentifier, title: title, index: i,
                                     minimized: AX.bool(w, kAXMinimizedAttribute) ?? false,
                                     focused: focusedWin.map { CFEqual($0, w) } ?? false))
                elements[id] = w
            }
        }

        async let tabs = BrowserTabs.chromeTabs(denied: denied)
        async let terms = TerminalSessions.all()
        let focused = FocusedElement.current(denied: denied)
        let terminals = await terms

        var snap = DesktopSnapshot(takenAt: Date(), apps: apps, windows: windows, tabs: await tabs, terminals: terminals,
                                   focused: focused, secureInputOn: IsSecureEventInputEnabled())
        if let id = preferredShellID, terminals.contains(where: { $0.id == id }) { snap.preferredShellID = id }
        if let active = snap.activeTab?.id, recentTabIDs.first != active {
            recentTabIDs.removeAll { $0 == active }
            recentTabIDs.insert(active, at: 0)
            if recentTabIDs.count > 6 { recentTabIDs.removeLast() }
        }
        recentTabIDs.removeAll { id in !snap.tabs.contains { $0.id == id } && !snap.tabs.isEmpty }
        snap.recentTabIDs = recentTabIDs
        if !denied.contains(front?.bundleIdentifier ?? "") {
            snap.terminalScreen = await TerminalSessions.frontScreen(terminals)
            if let front { snap.frontControls = await Self.controls(of: front) }
        }
        snap.takenAt = Date()
        snapshot = snap
        windowElements = elements
        lastBuildMs = Int(Date().timeIntervalSince(t0) * 1000)
        return snap
    }
}

extension SnapshotBuilder {
    /// Visible named controls of the front window, at most 80 spread across its areas, read
    /// in one fast pass (~0.1 s for Claude). For a browser, the page's own controls only.
    static func controls(of app: NSRunningApplication) async -> [String]? {
        if [TerminalSessions.terminalBundleID, TerminalSessions.itermBundleID, TerminalSessions.ghosttyBundleID]
            .contains(app.bundleIdentifier ?? "") { return nil }
        let browser = UIAdapter.browserBundleIDs.contains(app.bundleIdentifier ?? "")
        if browser { await UIAdapter.exposeTree(app) }
        let items = UIAdapter.elements(app.processIdentifier, limit: 250, budget: 0.35, inWebArea: browser)
        let names = UIAdapter.spread(items, max: 80).map(\.name)
        return names.isEmpty ? nil : names
    }
}

enum FocusedElement {
    static func current(denied: Set<String>) -> DesktopSnapshot.FocusedElement? {
        guard let el = AX.focusedElement(), let pid = AX.pid(el),
              let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        let name = app.localizedName ?? "?"
        let secure = AX.isSecure(el)
        let hidden = denied.contains(app.bundleIdentifier ?? "")
        var preview: String? = nil
        if !secure && !hidden, let v = AX.string(el, kAXValueAttribute), !v.isEmpty {
            preview = String(v.suffix(60))
        }
        return .init(app: name,
                     role: AX.string(el, kAXRoleAttribute) ?? "?",
                     subrole: AX.string(el, kAXSubroleAttribute),
                     placeholder: hidden ? nil : AX.string(el, kAXPlaceholderValueAttribute),
                     label: hidden ? nil : (AX.string(el, kAXDescriptionAttribute) ?? AX.string(el, kAXTitleAttribute)),
                     valuePreview: preview,
                     editable: AX.isEditable(el),
                     secure: secure)
    }
}
