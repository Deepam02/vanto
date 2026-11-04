import AppKit
import ApplicationServices
import VoiceCommandCore

/// Generic control of the front app over Accessibility (docs/generic-control.md): its menu
/// bar, and the named buttons, links and tabs in its front window, web pages in Chrome
/// included. Nothing here knows about a particular app or site.
@MainActor
enum UIAdapter {
    struct Item {
        let element: AXUIElement
        let name: String
        let path: String     // "View › Zoom Out" for menu items; the name otherwise
        let role: String
        let visible: Bool
        var region: Region = .main
    }

    /// Where a control sits in its window, for grouping ("Sidebar", "Near the text box").
    enum Region: String, CaseIterable {
        case sidebar = "Sidebar", toolbar = "Top bar", main = "Main", bottom = "Near the text box"

        static func of(_ f: CGRect, in w: CGRect) -> Region {
            guard !w.isNull, w.width > 0, w.height > 0 else { return .main }
            if f.midX < w.minX + w.width * 0.25 && f.width < w.width * 0.4 { return .sidebar }
            if f.midY > w.minY + w.height * 0.78 { return .bottom }
            if f.midY < w.minY + w.height * 0.12 { return .toolbar }
            return .main
        }
    }

    /// Browsers whose web content is exposed only once assistive technology is detected.
    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.brave.Browser",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
    ]

    /// Ask Chromium-based apps to build their accessibility tree: Electron's documented
    /// `AXManualAccessibility`, and `AXEnhancedUserInterface` for browsers' web content
    /// (Chromium turns web accessibility on when it sees it). Waits briefly the first time.
    static func exposeTree(_ app: NSRunningApplication) async {
        let el = AX.app(app.processIdentifier)
        var asked = false
        if AX.bool(el, "AXManualAccessibility") != true, AX.set(el, "AXManualAccessibility", kCFBooleanTrue) { asked = true }
        if browserBundleIDs.contains(app.bundleIdentifier ?? ""), AX.bool(el, "AXEnhancedUserInterface") != true,
           AX.set(el, "AXEnhancedUserInterface", kCFBooleanTrue) {
            asked = true
        }
        if asked { try? await Task.sleep(nanoseconds: 400_000_000) }
    }

    // MARK: Menus

    /// Every enabled menu item of the app, with its path. The Apple menu is skipped.
    static func menuItems(_ pid: pid_t, limit: Int = 800) -> [Item] {
        guard let bar = AX.element(AX.app(pid), kAXMenuBarAttribute) else { return [] }
        var out: [Item] = []
        func walk(_ el: AXUIElement, path: [String], depth: Int) {
            guard depth < 5, out.count < limit else { return }
            for child in AX.elements(el, kAXChildrenAttribute) {
                let role = AX.string(child, kAXRoleAttribute) ?? ""
                let title = AX.string(child, kAXTitleAttribute) ?? ""
                switch role {
                case kAXMenuBarItemRole:
                    if title.isEmpty || title == "Apple" { continue }
                    walk(child, path: [title], depth: depth + 1)
                case kAXMenuRole:
                    walk(child, path: path, depth: depth + 1)
                case kAXMenuItemRole where !title.isEmpty:
                    if let sub = AX.elements(child, kAXChildrenAttribute).first(where: { AX.string($0, kAXRoleAttribute) == kAXMenuRole }) {
                        walk(sub, path: path + [title], depth: depth + 1)
                    } else if AX.bool(child, kAXEnabledAttribute) != false {
                        out.append(Item(element: child, name: title, path: (path + [title]).joined(separator: " › "),
                                        role: role, visible: true))
                    }
                default:
                    continue
                }
            }
        }
        walk(bar, path: [], depth: 0)
        return out
    }

    static func topMenus(_ pid: pid_t) -> [String] {
        guard let bar = AX.element(AX.app(pid), kAXMenuBarAttribute) else { return [] }
        return AX.elements(bar, kAXChildrenAttribute).compactMap { AX.string($0, kAXTitleAttribute) }
            .filter { !$0.isEmpty && $0 != "Apple" }
    }

    static func menuCommand(item: String, menu: String?) async -> ExecOutcome {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .fail("No app in front") }
        let name = app.localizedName ?? "this app"
        let items = menuItems(app.processIdentifier)
        guard !items.isEmpty else { return .fail("\(name) has no menus I can read") }
        let query = [menu, item].compactMap { $0 }.joined(separator: " ")
        // Match the item's own title first; with a menu named, match the whole path.
        let pick = NameMatch.best(item, in: items.map(\.name)).flatMap { i -> Int? in
            guard let menu else { return i }
            return items[i].path.lowercased().hasPrefix(menu.lowercased()) ? i : nil
        } ?? NameMatch.best(query, in: items.map(\.path))
        guard let i = pick else { return .fail("No “\(item)” in \(name)'s menus") }
        guard AX.perform(items[i].element, kAXPressAction) else { return .fail("Couldn't run \(items[i].path)") }
        return .ok(items[i].path, undo: nil)
    }

    // MARK: Elements in the front window

    static let pressableRoles: Set<String> = [
        kAXButtonRole, "AXLink", kAXRadioButtonRole, kAXCheckBoxRole, kAXPopUpButtonRole, kAXMenuButtonRole,
        kAXMenuItemRole, "AXTab", kAXDisclosureTriangleRole, kAXCellRole, "AXTabButton", "AXToggle",
        // List and sidebar rows: Slack's channels and DMs ("Deepam Goyal (you, active)", 4 Nov dump).
        kAXRowRole,
    ]

    static let walkAttributes = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute,
                                 kAXPositionAttribute, kAXSizeAttribute, kAXValueAttribute]

    /// Named, pressable elements of the front window, breadth first (so sidebars and toolbars
    /// come before long content), within a time budget. Electron apps answer each call in
    /// milliseconds (a full walk of Claude took over a minute on 4 Nov), so every element
    /// costs one batched call, and the walk stops at the budget.
    /// `inWebArea` keeps only elements inside a web page (a browser's own buttons are left out).
    static func elements(_ pid: pid_t, limit: Int = 300, maxVisited: Int = 3000, budget: TimeInterval = 0.8,
                         inWebArea: Bool = false) -> [Item] {
        let axApp = AX.app(pid)
        guard let window = AX.element(axApp, kAXFocusedWindowAttribute) ?? AX.element(axApp, kAXMainWindowAttribute) else { return [] }
        let bounds = AX.frame(window) ?? .null
        let deadline = Date().addingTimeInterval(budget)
        var out: [Item] = []
        var queue: [(el: AXUIElement, depth: Int, web: Bool)] = [(window, 0, false)]
        var head = 0
        func frame(_ pos: CFTypeRef?, _ size: CFTypeRef?) -> CGRect? {
            guard let pos, let size, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var p = CGPoint.zero, s = CGSize.zero
            guard AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
            return CGRect(origin: p, size: s)
        }
        while head < queue.count, head < maxVisited, out.count < limit, Date() < deadline {
            let (el, depth, web) = queue[head]
            head += 1
            let v = AX.values(el, walkAttributes)
            let role = v[0] as? String ?? ""
            let children = v[3] as? [AXUIElement] ?? []
            let inWeb = web || role == "AXWebArea"
            if pressableRoles.contains(role), !inWebArea || inWeb {
                var name = [v[1], v[2]].compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
                if name.isEmpty {
                    // Web links and buttons often carry their text in a child.
                    name = children.prefix(3).compactMap { c -> String? in
                        let cv = AX.values(c, [kAXValueAttribute, kAXTitleAttribute])
                        return (cv[0] as? String) ?? (cv[1] as? String)
                    }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !name.isEmpty, name.count <= 80 {
                    let f = frame(v[4], v[5])
                    // Virtualised list items report 1 px heights: not really on screen.
                    let visible = f.map { $0.width > 2 && $0.height >= 4 && (bounds.isNull || bounds.intersects($0)) } ?? false
                    var item = Item(element: el, name: name, path: name, role: role, visible: visible)
                    if let f { item.region = Region.of(f, in: bounds) }
                    out.append(item)
                }
                // A button's children are its own label; rows and cells hold more controls.
                if role != kAXCellRole && role != kAXRowRole { continue }
            }
            if depth < 60 { queue.append(contentsOf: children.map { ($0, depth + 1, inWeb) }) }
        }
        return out
    }

    static func click(name: String) async -> ExecOutcome {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .fail("No app in front") }
        await exposeTree(app)
        // In a browser, look inside the page first: "new" on 4 Nov clicked Chrome's own New Tab.
        let browser = browserBundleIDs.contains(app.bundleIdentifier ?? "")
        let pid = app.processIdentifier
        var all = elements(pid, limit: 600, budget: 1.5, inWebArea: browser)
        if NameMatch.best(name, in: all.map(\.name)) == nil {
            // A page may still be loading after the last click ("Limits" missed on 4 Nov): look again.
            try? await Task.sleep(nanoseconds: 500_000_000)
            all = elements(pid, limit: 600, budget: 1.5, inWebArea: browser)
            if browser && NameMatch.best(name, in: all.map(\.name)) == nil { all = elements(pid, limit: 600, budget: 1.5) }
        }
        // Visible first, so a nav link on screen beats one hidden in a collapsed menu; tree
        // order (top to bottom) is kept within each group.
        let items = all.filter(\.visible) + all.filter { !$0.visible }
        let appName = app.localizedName ?? "this app"
        guard !items.isEmpty else { return .fail("I can't see any buttons in \(appName)") }
        guard let i = NameMatch.best(name, in: items.map(\.name)) else {
            return .fail("No “\(name)” on screen in \(appName)")
        }
        let item = items[i]
        if AX.perform(item.element, kAXPressAction) { return .ok("Clicked “\(item.name)”", undo: nil) }
        // Some web elements have no press action: click their centre instead.
        if item.visible, let f = AX.frame(item.element) {
            KeyPresser.click(at: CGPoint(x: f.midX, y: f.midY))
            return .ok("Clicked “\(item.name)”", undo: nil)
        }
        return .fail("Couldn't click “\(item.name)”")
    }

    // MARK: Text box, and what's here

    static func focusTextBox(app query: String?, hints: AppHints, snapshot: DesktopSnapshot) async -> ExecOutcome {
        guard let target = query ?? NSWorkspace.shared.frontmostApplication?.localizedName else { return .fail("No app in front") }
        if let running = AppWindowAdapter.resolveApp(target, snapshot: snapshot).running { await exposeTree(running) }
        do {
            let t = try await TextInputResolver.resolveChatBox(appQuery: target, hints: hints, snapshot: snapshot)
            if (try? TextInputResolver.focusedEditable(in: t.pid)) == nil {
                _ = try await TextInputResolver.focus(t.element, pid: t.pid)
            }
            return .ok("Cursor is in \(t.appName)'s text box", undo: nil)
        } catch {
            return .fail("\(error)")
        }
    }

    /// Visible named controls, a fair share from each area of the window, so a sidebar full of
    /// chats doesn't crowd out the controls by the text box (4 Nov: "change the effort level").
    static func spread(_ items: [Item], max: Int) -> [Item] {
        var seen = Set<String>()
        let unique = items.filter { $0.visible && $0.name.count >= 2 && seen.insert($0.name.lowercased()).inserted }
        var byRegion = Dictionary(grouping: unique, by: \.region)
        var out: [Item] = []
        while out.count < max, byRegion.values.contains(where: { !$0.isEmpty }) {
            for r in Region.allCases where out.count < max {
                if var list = byRegion[r], !list.isEmpty { out.append(list.removeFirst()); byRegion[r] = list }
            }
        }
        return out
    }

    /// "What can you do here?": the names on screen by area, the app's menus, and examples.
    static func describe() async -> (summary: String, card: HelpCard?) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return ("No app in front", nil) }
        await exposeTree(app)
        let name = app.localizedName ?? "This app"
        let browser = browserBundleIDs.contains(app.bundleIdentifier ?? "")
        let shown = spread(elements(app.processIdentifier, limit: 400, budget: 1.0, inWebArea: browser), max: 48)
        var sections: [HelpCard.Section] = []
        for r in Region.allCases {
            let names = shown.filter { $0.region == r }.map(\.name).prefix(12)
            if !names.isEmpty { sections.append(.init(title: r.rawValue, items: Array(names))) }
        }
        if !browser {
            let menus = Array(topMenus(app.processIdentifier).dropFirst().prefix(8))    // skip the app-name menu
            if !menus.isEmpty { sections.append(.init(title: "Menus (say any command in them)", items: menus)) }
        }
        sections.append(.init(title: "Anywhere", items: [
            "switch to Slack", "go to the GitHub tab", "the other window", "focus the text box",
            "write a message, wait for me", "improve the English", "run the command that lists folders",
            "scroll down", "keep scrolling", "undo that",
        ]))
        let card = HelpCard(title: "In \(name), you can say", subtitle: "Say a name below, or “click …”. Speaking hides this.",
                            sections: sections)
        return ("\(name): \(shown.count) things on screen, shown below", card)
    }
}
