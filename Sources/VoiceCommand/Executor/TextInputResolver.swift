import AppKit
import VoiceCommandCore

/// Finds the chat input in an app ("Finding a chat input anywhere"), steps 1–3:
/// per-app hint, already-focused field, Accessibility search of the front window.
/// The screenshot/vision step is cut from the MVP (Final review 9).
/// Typing into the wrong place is the worst failure, so focus is always re-verified.
@MainActor
enum TextInputResolver {
    struct Target {
        let pid: pid_t
        let element: AXUIElement
        let appName: String
        let bundleID: String?
    }

    enum Failure: Error, CustomStringConvertible {
        case appNotFound(String), noInput(String), secure, notFront(String)
        var description: String {
            switch self {
            case .appNotFound(let a): return "Couldn't find \(a)"
            case .noInput(let a): return "Couldn't find a chat box in \(a)"
            case .secure: return "That's a password field — not typing"
            case .notFront(let a): return "\(a) didn't come to the front"
            }
        }
    }

    /// The focused element if it is editable, in `pid`, and not a password field.
    static func focusedEditable(in pid: pid_t?) throws -> AXUIElement? {
        guard let el = AX.focusedElement() else { return nil }
        if AX.isSecure(el) { throw Failure.secure }
        if let pid, AX.pid(el) != pid { return nil }
        return AX.isEditable(el) ? el : nil
    }

    /// Resolve the composer of `appQuery` (bring the app forward first).
    static func resolveChatBox(appQuery: String, hints: AppHints, snapshot: DesktopSnapshot) async throws -> Target {
        let (_, runningApp) = AppWindowAdapter.resolveApp(appQuery, snapshot: snapshot)
        var app = runningApp
        if app == nil {
            guard case .ok = await AppWindowAdapter.openApp(appQuery, snapshot: snapshot) else { throw Failure.appNotFound(appQuery) }
            app = NSWorkspace.shared.frontmostApplication
        }
        guard let app else { throw Failure.appNotFound(appQuery) }
        let pid = app.processIdentifier
        let name = app.localizedName ?? appQuery
        if AppWindowAdapter.frontmostPID() != pid {
            guard await AppWindowAdapter.refocus(pid: pid) else { throw Failure.notFront(name) }
        }
        let hint = hints.hint(bundleID: app.bundleIdentifier) ?? hints.hint(named: name)

        // Chromium/Electron apps build no AX tree until asked; give it a moment the first time.
        AX.enableElectronAccessibility(pid)

        // 1. Per-app hint.
        if let hint {
            switch hint.focus {
            case .shortcutIfNotFocused:
                // Cursor's ⌘L toggles the chat, so press it only if focus isn't already in an input.
                if let el = try focusedEditable(in: pid) { return Target(pid: pid, element: el, appName: name, bundleID: app.bundleIdentifier) }
                if let keys = hint.focusKeys { _ = KeyPresser.press(keys) }
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    if let el = try focusedEditable(in: pid) { return Target(pid: pid, element: el, appName: name, bundleID: app.bundleIdentifier) }
                }
            case .focusedOnly:
                if let el = try focusedEditable(in: pid) { return Target(pid: pid, element: el, appName: name, bundleID: app.bundleIdentifier) }
                throw Failure.noInput(name)
            case .terminal:
                throw Failure.noInput(name)
            case .bottomTextArea, .labelled:
                break
            }
        }

        // 2. Already focused.
        if let el = try focusedEditable(in: pid) { return Target(pid: pid, element: el, appName: name, bundleID: app.bundleIdentifier) }

        // 3. Accessibility search of the front window (retry once while an Electron tree builds).
        for attempt in 0..<2 {
            if let el = bestCandidate(pid: pid, label: hint?.focus == .labelled ? hint?.labelContains : nil) {
                if try await focus(el, pid: pid) { return Target(pid: pid, element: el, appName: name, bundleID: app.bundleIdentifier) }
            }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 400_000_000) }
        }
        throw Failure.noInput(name)
    }

    /// Focus the element, falling back to a click at its centre; then verify.
    static func focus(_ el: AXUIElement, pid: pid_t) async throws -> Bool {
        AX.set(el, kAXFocusedAttribute, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 60_000_000)
        if try focusedEditable(in: pid) != nil { return true }
        if let f = AX.frame(el) {
            KeyPresser.click(at: CGPoint(x: f.midX, y: f.midY))
            try? await Task.sleep(nanoseconds: 120_000_000)
            if try focusedEditable(in: pid) != nil { return true }
        }
        return false
    }

    static let boxAttributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                                kAXPlaceholderValueAttribute, kAXHelpAttribute, "AXEditable", kAXChildrenAttribute,
                                kAXPositionAttribute, kAXSizeAttribute]

    /// Score editable elements in the focused window: near the bottom, chat-like
    /// placeholder words, wide, near a Send button. Breadth first with one batched call per
    /// element and a time budget: the old walk took minutes on Claude (4 Nov), and stopped
    /// at a window-sized "editable" wrapper before reaching the real box.
    static func bestCandidate(pid: pid_t, label: String?, budget: TimeInterval = 1.2) -> AXUIElement? {
        let axApp = AX.app(pid)
        guard let window = AX.element(axApp, kAXFocusedWindowAttribute) ?? AX.element(axApp, kAXMainWindowAttribute),
              let wf = AX.frame(window), wf.height > 0 else { return nil }
        var candidates: [(el: AXUIElement, score: Double, frame: CGRect)] = []
        var sendButtons: [CGRect] = []
        let deadline = Date().addingTimeInterval(budget)
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var head = 0
        while head < queue.count, head < 6000, Date() < deadline {
            let (el, depth) = queue[head]
            head += 1
            let v = AX.values(el, boxAttributes)
            let role = v[0] as? String ?? ""
            let subrole = v[1] as? String
            let text = [v[2], v[3], v[4], v[5]].compactMap { ($0 as? String)?.lowercased() }.joined(separator: " ")
            var f: CGRect?
            if let pos = v[8], let size = v[9], CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
                var p = CGPoint.zero, sz = CGSize.zero
                if AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &sz) { f = CGRect(origin: p, size: sz) }
            }
            if role == kAXButtonRole, text.contains("send") || text.contains("submit"), let f { sendButtons.append(f) }
            let flaggedEditable = (v[6] as? NSNumber)?.boolValue == true
            // Text roles always count; a contenteditable group only if input-sized (Electron
            // wraps whole windows in "editable" groups).
            let editable = AX.textRoles.contains(role) || (flaggedEditable && (role != kAXGroupRole || (f?.height ?? .infinity) < 400))
            let secure = subrole == "AXSecureTextField" || role == "AXSecureTextField"
            if editable, !secure, let f, f.width > 40, f.height > 8 {
                var score = 0.0
                score += (f.midY - wf.minY) / wf.height * 4         // 0 top … 1 bottom
                score += min(f.width / wf.width, 1) * 2
                for w in ["message", "ask", "reply", "prompt", "chat", "send", "write", "plan, search, build", "type"] where text.contains(w) { score += 3; break }
                if let label, text.contains(label.lowercased()) { score += 6 }
                if role == kAXTextAreaRole || flaggedEditable { score += 1 }
                if text.contains("search") && !text.contains("message") { score -= 3 }
                candidates.append((el, score, f))
                continue     // an editable element's children are its own text
            }
            if depth < 60, let children = v[7] as? [AXUIElement] { queue.append(contentsOf: children.map { ($0, depth + 1) }) }
        }
        guard !candidates.isEmpty else { return nil }
        // Bonus for a Send button just to the right of / below an input.
        let scored = candidates.map { c -> (el: AXUIElement, score: Double, frame: CGRect) in
            let near = sendButtons.contains { abs($0.midY - c.frame.midY) < 80 || ($0.minY >= c.frame.minY && $0.minY - c.frame.maxY < 60) }
            return (c.el, c.score + (near ? 2 : 0), c.frame)
        }.sorted { $0.score > $1.score }
        // Near-tie: the lower one on screen is the composer far more often than not.
        if scored.count > 1, scored[0].score - scored[1].score < 0.5 {
            return scored[0].frame.maxY >= scored[1].frame.maxY ? scored[0].el : scored[1].el
        }
        return scored[0].el
    }
}
