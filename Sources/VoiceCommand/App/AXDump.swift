import AppKit
import ApplicationServices

/// Debug dump of an app's accessibility tree (`--dump-ax`), one element per line, indented.
@MainActor
enum AXDump {
    static func write(app name: String, to path: String) async {
        var lines: [String] = []
        let running = NSWorkspace.shared.runningApplications.first {
            ($0.localizedName ?? "").caseInsensitiveCompare(name) == .orderedSame || $0.bundleIdentifier == name
        }
        guard let running else {
            try? "No running app called \(name)".write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        await UIAdapter.exposeTree(running)
        try? await Task.sleep(nanoseconds: 800_000_000)
        let app = AX.app(running.processIdentifier)
        lines.append("app \(name) pid \(running.processIdentifier) trusted \(AXIsProcessTrusted())")
        lines.append("AXManualAccessibility=\(AX.bool(app, "AXManualAccessibility").map(String.init) ?? "nil") AXEnhancedUserInterface=\(AX.bool(app, "AXEnhancedUserInterface").map(String.init) ?? "nil")")
        var count = 0
        func describe(_ el: AXUIElement) -> String {
            var parts = [AX.string(el, kAXRoleAttribute) ?? "?"]
            if let s = AX.string(el, kAXSubroleAttribute) { parts.append("sub=\(s)") }
            for (label, attr) in [("title", kAXTitleAttribute), ("desc", kAXDescriptionAttribute), ("help", kAXHelpAttribute),
                                  ("placeholder", kAXPlaceholderValueAttribute), ("id", "AXIdentifier")] {
                if let v = AX.string(el, attr), !v.isEmpty { parts.append("\(label)=\"\(v.prefix(60))\"") }
            }
            if let v = AX.string(el, kAXValueAttribute), !v.isEmpty { parts.append("value=\"\(v.prefix(40))\"") }
            if AX.isEditable(el) { parts.append("EDITABLE") }
            if AX.bool(el, kAXFocusedAttribute) == true { parts.append("FOCUSED") }
            if let f = AX.frame(el) { parts.append("frame=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))") }
            var names: CFArray?
            if AXUIElementCopyActionNames(el, &names) == .success, let a = names as? [String], !a.isEmpty {
                parts.append("actions=\(a.filter { !$0.hasPrefix("AXScroll") }.joined(separator: ","))")
            }
            return parts.joined(separator: " ")
        }
        // Batched reads: one call per element (per-attribute walks take minutes on Electron).
        let attrs = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                     kAXValueAttribute, kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute]
        func walk(_ el: AXUIElement, depth: Int) {
            guard count < 8000, depth < 80 else { return }
            count += 1
            let v = AX.values(el, attrs)
            var parts = [v[0] as? String ?? "?"]
            if let s = v[1] as? String { parts.append("sub=\(s)") }
            if let s = v[2] as? String, !s.isEmpty { parts.append("title=\"\(s.prefix(60))\"") }
            if let s = v[3] as? String, !s.isEmpty { parts.append("desc=\"\(s.prefix(60))\"") }
            if let s = v[4] as? String, !s.isEmpty { parts.append("value=\"\(s.prefix(40).replacingOccurrences(of: "\n", with: " "))\"") }
            if let pos = v[6], let size = v[7], CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
                var pt = CGPoint.zero, sz = CGSize.zero
                if AXValueGetValue(pos as! AXValue, .cgPoint, &pt), AXValueGetValue(size as! AXValue, .cgSize, &sz) {
                    parts.append("frame=\(Int(pt.x)),\(Int(pt.y)) \(Int(sz.width))x\(Int(sz.height))")
                }
            }
            lines.append(String(repeating: "  ", count: depth) + parts.joined(separator: " "))
            for child in (v[5] as? [AXUIElement]) ?? [] { walk(child, depth: depth + 1) }
        }
        let t0 = Date()
        let fast = UIAdapter.elements(running.processIdentifier)
        lines.append("fast walk: \(fast.count) controls in \(Int(Date().timeIntervalSince(t0) * 1000)) ms: " +
                     fast.map { "\($0.name)\($0.visible ? "" : "(hidden)")" }.joined(separator: " | "))
        let t1 = Date()
        if let box = TextInputResolver.bestCandidate(pid: running.processIdentifier, label: nil) {
            lines.append("chat box (\(Int(Date().timeIntervalSince(t1) * 1000)) ms): \(describe(box))")
        } else {
            lines.append("chat box: none found")
        }
        if !CommandLine.arguments.contains("--fast-only") {
            for w in AX.elements(app, kAXWindowsAttribute) { walk(w, depth: 0) }
        }
        lines.append("\(count) elements")
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
