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

    /// Score editable elements in the focused window: near the bottom, chat-like
    /// placeholder words, wide, near a Send button.
    static func bestCandidate(pid: pid_t, label: String?) -> AXUIElement? {
        let axApp = AX.app(pid)
        guard let window = AX.element(axApp, kAXFocusedWindowAttribute) ?? AX.element(axApp, kAXMainWindowAttribute),
              let wf = AX.frame(window), wf.height > 0 else { return nil }
        var candidates: [(AXUIElement, Double)] = []
        var sendButtons: [CGRect] = []
        var visited = 0
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth < 45, visited < 4000 else { return }
            visited += 1
            let role = AX.string(el, kAXRoleAttribute) ?? ""
            if role == kAXButtonRole {
                let t = ((AX.string(el, kAXTitleAttribute) ?? "") + " " + (AX.string(el, kAXDescriptionAttribute) ?? "")).lowercased()
                if t.contains("send") || t.contains("submit"), let f = AX.frame(el) { sendButtons.append(f) }
            }
            if AX.isEditable(el), !AX.isSecure(el), let f = AX.frame(el), f.width > 40, f.height > 8 {
                var score = 0.0
                let rel = (f.midY - wf.minY) / wf.height                  // 0 top … 1 bottom
                score += rel * 4
                score += min(f.width / wf.width, 1) * 2
                let words = [AX.string(el, kAXPlaceholderValueAttribute), AX.string(el, kAXDescriptionAttribute),
                             AX.string(el, kAXTitleAttribute), AX.string(el, kAXHelpAttribute)]
                    .compactMap { $0?.lowercased() }.joined(separator: " ")
                for w in ["message", "ask", "reply", "prompt", "chat", "send", "write", "plan, search, build", "type"] where words.contains(w) { score += 3; break }
                if let label, words.contains(label.lowercased()) { score += 6 }
                if role == kAXTextAreaRole || AX.bool(el, "AXEditable") == true { score += 1 }
                if words.contains("search") && !words.contains("message") { score -= 3 }
                candidates.append((el, score))
                return     // don't descend into an editable element's children
            }
            for child in AX.elements(el, kAXChildrenAttribute) { walk(child, depth: depth + 1) }
        }
        walk(window, depth: 0)
        guard !candidates.isEmpty else { return nil }
        // Bonus for a Send button just to the right of / below an input.
        let scored = candidates.map { (el, s) -> (AXUIElement, Double) in
            guard let f = AX.frame(el) else { return (el, s) }
            let near = sendButtons.contains { abs($0.midY - f.midY) < 80 || ($0.minY >= f.minY && $0.minY - f.maxY < 60) }
            return (el, s + (near ? 2 : 0))
        }.sorted { $0.1 > $1.1 }
        // "Clearly wins": the best must beat the runner-up, unless it's alone.
        if scored.count > 1, scored[0].1 - scored[1].1 < 0.5 { return nil }
        return scored[0].0
    }
}
