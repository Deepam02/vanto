import AppKit
import VoiceCommandCore

/// open_app and focus_window. Since macOS 14 activation is cooperative, so this uses
/// NSWorkspace.openApplication (activates = true), verifies the app is frontmost, and
/// retries once by raising a window through Accessibility.
@MainActor
enum AppWindowAdapter {
    static func frontmostPID() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    static func waitFrontmost(_ pid: pid_t, timeout: TimeInterval) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if frontmostPID() == pid { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return frontmostPID() == pid
    }

    /// Resolve a spoken app name or bundle ID to an installed app.
    static func resolveApp(_ query: String, snapshot: DesktopSnapshot) -> (url: URL?, running: NSRunningApplication?) {
        let q = query.trimmingCharacters(in: .whitespaces)
        let lower = q.lowercased()
        let runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if let r = runningApps.first(where: { $0.bundleIdentifier?.lowercased() == lower })
            ?? runningApps.first(where: { $0.localizedName?.lowercased() == lower })
            ?? runningApps.first(where: { ($0.localizedName?.lowercased()).map { $0.hasPrefix(lower) || lower.hasPrefix($0) } ?? false }) {
            return (r.bundleURL, r)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: q) { return (url, nil) }
        // Search the usual app folders by name.
        let fm = FileManager.default
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            if let hit = items.first(where: { $0.lowercased() == lower + ".app" })
                ?? items.first(where: { $0.lowercased().hasSuffix(".app") && $0.lowercased().hasPrefix(lower) }) {
                return (URL(fileURLWithPath: dir).appendingPathComponent(hit), nil)
            }
        }
        return (nil, nil)
    }

    static func openApp(_ query: String, snapshot: DesktopSnapshot) async -> ExecOutcome {
        let previous = frontmostPID()
        let (url, running) = resolveApp(query, snapshot: snapshot)
        guard let url else { return .fail("Couldn't find an app called \(query)") }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        let app: NSRunningApplication? = await withCheckedContinuation { cont in
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, _ in cont.resume(returning: app) }
        } ?? running
        guard let app else { return .fail("Couldn't open \(query)") }
        let name = app.localizedName ?? query
        let launched = running == nil
        if await waitFrontmost(app.processIdentifier, timeout: launched ? 3.0 : 0.6) {
            return .ok("Switched to \(name)", undo: previous.map { .refocus(pid: $0) })
        }
        // Retry once through Accessibility.
        let axApp = AX.app(app.processIdentifier)
        AX.set(axApp, kAXFrontmostAttribute, kCFBooleanTrue)
        if let w = AX.element(axApp, kAXMainWindowAttribute) ?? AX.elements(axApp, kAXWindowsAttribute).first { AX.perform(w, kAXRaiseAction) }
        if await waitFrontmost(app.processIdentifier, timeout: 0.5) {
            return .ok("Switched to \(name)", undo: previous.map { .refocus(pid: $0) })
        }
        return .fail("\(name) didn't come to the front")
    }

    static func focusWindow(_ id: String, snapshot: DesktopSnapshot, elements: [String: AXUIElement]) async -> ExecOutcome {
        guard let info = snapshot.window(id), let el = elements[id] else { return .fail("That window isn't open any more") }
        let previous = frontmostPID()
        guard let app = NSRunningApplication(processIdentifier: info.pid) else { return .fail("\(info.app) quit") }
        if info.minimized { AX.set(el, kAXMinimizedAttribute, kCFBooleanFalse) }
        if frontmostPID() != info.pid, let url = app.bundleURL {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            _ = await withCheckedContinuation { cont in
                NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in cont.resume(returning: ()) }
            }
        }
        // A window on another Space switches Spaces first; AXRaise can fail mid-switch.
        _ = await waitFrontmost(info.pid, timeout: 0.5)
        AX.perform(el, kAXRaiseAction)
        AX.set(el, kAXMainAttribute, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 80_000_000)
        let axApp = AX.app(info.pid)
        if let focused = AX.element(axApp, kAXFocusedWindowAttribute), CFEqual(focused, el), frontmostPID() == info.pid {
            return .ok("Showing \(info.app): \(DesktopSnapshot.clipTitle(info.title))", undo: previous.map { .refocus(pid: $0) })
        }
        AX.perform(el, kAXRaiseAction)
        _ = await waitFrontmost(info.pid, timeout: 0.3)
        if frontmostPID() == info.pid {
            return .ok("Showing \(info.app): \(DesktopSnapshot.clipTitle(info.title))", undo: previous.map { .refocus(pid: $0) })
        }
        return .fail("Couldn't bring that \(info.app) window forward")
    }

    static func refocus(pid: pid_t) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), let url = app.bundleURL else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        _ = await withCheckedContinuation { cont in
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in cont.resume(returning: ()) }
        }
        return await waitFrontmost(pid, timeout: 0.6)
    }

    /// Centre of the front window, for scroll events.
    static func frontWindowCenter() -> CGPoint? {
        guard let pid = frontmostPID(), let w = AX.element(AX.app(pid), kAXFocusedWindowAttribute), let f = AX.frame(w) else { return nil }
        return CGPoint(x: f.midX, y: f.midY)
    }
}

extension DesktopSnapshot {
    static func clipTitle(_ s: String) -> String { s.count > 40 ? String(s.prefix(39)) + "…" : s }
}
