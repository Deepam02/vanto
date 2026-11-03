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
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var building = false
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
        if building { return snapshot }
        building = true
        defer { building = false }
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

        var snap = DesktopSnapshot(takenAt: Date(), apps: apps, windows: windows, tabs: await tabs, terminals: await terms,
                                   focused: focused, secureInputOn: IsSecureEventInputEnabled())
        snap.takenAt = Date()
        snapshot = snap
        windowElements = elements
        lastBuildMs = Int(Date().timeIntervalSince(t0) * 1000)
        return snap
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
