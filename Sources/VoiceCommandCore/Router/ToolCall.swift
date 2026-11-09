import Foundation

public enum TypeTarget: String, Codable, Sendable { case focused, chat_box, terminal }
public enum CommandSource: String, Codable, Sendable { case verbatim, composed }
public enum CommandRisk: String, Codable, Sendable { case read_only, changes_files, destructive, network_or_deploy }
public enum NavigateAction: String, Codable, Sendable { case reload, back, forward }
public enum ScrollDirection: String, Codable, Sendable { case up, down, left, right }
public enum ScrollAmount: String, Codable, Sendable { case small, page, continuous }
public enum VolumeAction: String, Codable, Sendable { case up, down, set, mute, unmute }

/// One validated tool call from the router. With `eager_input_streaming` the API does not
/// validate inputs, so every field is checked here before anything can run.
public enum ToolCall: Equatable, Sendable {
    case waitForMore
    case ignore
    case say(message: String)
    case endSession
    case confirmPending
    case cancelPending
    case undoLast
    case openApp(app: String)
    case focusWindow(windowID: String)
    case browserSwitchTab(tabID: String)
    case browserOpenURL(url: String, newTab: Bool)
    case browserNewTab
    case browserCloseTab(tabID: String)
    case browserNavigate(NavigateAction)
    /// `here`: use the search box of the site in the active tab instead of Google.
    case browserSearch(query: String, here: Bool = false)
    case terminalFocus(sessionID: String)
    case terminalNew(cwd: String?)
    case terminalRun(sessionID: String, command: String, source: CommandSource, risk: CommandRisk)
    /// `composed`: text the router wrote because the person asked it to write something.
    case typeText(target: TypeTarget, app: String?, sessionID: String?, payload: String, source: CommandSource = .verbatim)
    case newline
    case clearTyped
    case submit(app: String?, sendPhrase: String)
    case pressKeys(keys: String)
    case scroll(direction: ScrollDirection, amount: ScrollAmount)
    // Generic control of the front app (docs/generic-control.md): no per-app code.
    case menuCommand(item: String, menu: String?)
    /// `near`: which of several same-named controls ("text box", "sidebar", "top", "main").
    case clickElement(name: String, near: String? = nil)
    case focusTextBox(app: String?)
    case describeScreen
    /// The rest of the request needs the screen after this reply's actions: look again and finish it.
    case lookAgain
    // Drafts and dictation.
    case rewriteDraft(text: String)
    case startDictation(target: TypeTarget, app: String?, sessionID: String?, text: String?)
    case systemVolume(action: VolumeAction, level: Int?)

    public var name: String {
        switch self {
        case .waitForMore: return "wait_for_more"
        case .ignore: return "ignore"
        case .say: return "say"
        case .endSession: return "end_session"
        case .confirmPending: return "confirm_pending"
        case .cancelPending: return "cancel_pending"
        case .undoLast: return "undo_last"
        case .openApp: return "open_app"
        case .focusWindow: return "focus_window"
        case .browserSwitchTab: return "browser_switch_tab"
        case .browserOpenURL: return "browser_open_url"
        case .browserNewTab: return "browser_new_tab"
        case .browserCloseTab: return "browser_close_tab"
        case .browserNavigate: return "browser_navigate"
        case .browserSearch: return "browser_search"
        case .terminalFocus: return "terminal_focus"
        case .terminalNew: return "terminal_new"
        case .terminalRun: return "terminal_run"
        case .typeText: return "type_text"
        case .newline: return "newline"
        case .clearTyped: return "clear_typed"
        case .submit: return "submit"
        case .pressKeys: return "press_keys"
        case .scroll: return "scroll"
        case .menuCommand: return "menu_command"
        case .clickElement: return "click_element"
        case .focusTextBox: return "focus_text_box"
        case .describeScreen: return "describe_screen"
        case .lookAgain: return "look_again"
        case .rewriteDraft: return "rewrite_draft"
        case .startDictation: return "start_dictation"
        case .systemVolume: return "system_volume"
        }
    }

    /// Compact, log-friendly description, e.g. `open_app(app: Cursor)`.
    public var summary: String {
        switch self {
        case .say(let m): return "say(\(m))"
        case .openApp(let a): return "open_app(\(a))"
        case .focusWindow(let w): return "focus_window(\(w))"
        case .browserSwitchTab(let t): return "browser_switch_tab(\(t))"
        case .browserOpenURL(let u, let n): return "browser_open_url(\(u), new_tab: \(n))"
        case .browserCloseTab(let t): return "browser_close_tab(\(t))"
        case .browserNavigate(let a): return "browser_navigate(\(a.rawValue))"
        case .browserSearch(let q, let here): return "browser_search(\(q)\(here ? ", here" : ""))"
        case .terminalFocus(let s): return "terminal_focus(\(s))"
        case .terminalNew(let c): return "terminal_new(\(c ?? ""))"
        case .terminalRun(let s, let c, let src, let r): return "terminal_run(\(s), \"\(c)\", \(src.rawValue), \(r.rawValue))"
        case .typeText(let t, let a, let s, let p, let src):
            return "type_text(\(t.rawValue)\(a.map { ", app: \($0)" } ?? "")\(s.map { ", session: \($0)" } ?? ""), \"\(p)\"\(src == .composed ? ", composed" : ""))"
        case .submit(let a, let p): return "submit(\(a ?? "")\(a == nil ? "" : ", ")\"\(p)\")"
        case .pressKeys(let k): return "press_keys(\(k))"
        case .scroll(let d, let a): return "scroll(\(d.rawValue), \(a.rawValue))"
        case .menuCommand(let i, let m): return "menu_command(\(m.map { "\($0) › " } ?? "")\(i))"
        case .clickElement(let n, let near): return "click_element(\(n)\(near.map { ", near \($0)" } ?? ""))"
        case .focusTextBox(let a): return "focus_text_box(\(a ?? "front app"))"
        case .rewriteDraft(let t): return "rewrite_draft(\"\(t)\")"
        case .systemVolume(let a, let l): return "system_volume(\(a.rawValue)\(l.map { ", \($0)" } ?? ""))"
        case .startDictation(let t, let a, let s, let x):
            return "start_dictation(\(t.rawValue)\(a.map { ", app: \($0)" } ?? "")\(s.map { ", session: \($0)" } ?? "")\(x.map { ", \"\($0)\"" } ?? ""))"
        default: return name
        }
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknownTool(String)
        case invalidInput(String)
        public var description: String {
            switch self {
            case .unknownTool(let n): return "unknown tool \(n)"
            case .invalidInput(let m): return "invalid input: \(m)"
            }
        }
    }

    /// Parse and validate a tool call from its name and raw (accumulated) JSON input.
    public static func parse(name: String, inputJSON: String) throws -> ToolCall {
        let trimmed = inputJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let obj: [String: Any]
        if trimmed.isEmpty {
            obj = [:]
        } else {
            guard let data = trimmed.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data),
                  let dict = parsed as? [String: Any] else {
                throw ParseError.invalidInput("not a JSON object: \(trimmed.prefix(80))")
            }
            obj = dict
        }
        return try parse(name: name, input: obj)
    }

    public static func parse(name: String, input: [String: Any]) throws -> ToolCall {
        func str(_ key: String) throws -> String {
            guard let v = input[key] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ParseError.invalidInput("\(name).\(key) missing")
            }
            return v
        }
        func optStr(_ key: String) -> String? {
            guard let v = input[key] as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        func enumValue<E: RawRepresentable>(_ key: String, _ type: E.Type, default def: E? = nil) throws -> E where E.RawValue == String {
            if let raw = input[key] as? String, let v = E(rawValue: raw) { return v }
            if input[key] == nil, let def { return def }
            throw ParseError.invalidInput("\(name).\(key) invalid")
        }

        switch name {
        case "wait_for_more": return .waitForMore
        case "ignore": return .ignore
        case "say": return .say(message: try str("message"))
        case "end_session": return .endSession
        case "confirm_pending": return .confirmPending
        case "cancel_pending": return .cancelPending
        case "undo_last": return .undoLast
        case "open_app": return .openApp(app: try str("app"))
        case "focus_window": return .focusWindow(windowID: try str("window_id"))
        case "browser_switch_tab": return .browserSwitchTab(tabID: try str("tab_id"))
        case "browser_open_url":
            let newTab = (input["new_tab"] as? Bool) ?? true
            return .browserOpenURL(url: try str("url"), newTab: newTab)
        case "browser_new_tab": return .browserNewTab
        case "browser_close_tab": return .browserCloseTab(tabID: try str("tab_id"))
        case "browser_navigate": return .browserNavigate(try enumValue("action", NavigateAction.self))
        case "browser_search": return .browserSearch(query: try str("query"), here: (input["here"] as? Bool) ?? false)
        case "terminal_focus": return .terminalFocus(sessionID: try str("session_id"))
        case "terminal_new": return .terminalNew(cwd: optStr("cwd"))
        case "terminal_run":
            return .terminalRun(
                sessionID: try str("session_id"),
                command: try str("command"),
                source: try enumValue("source", CommandSource.self),
                risk: try enumValue("risk", CommandRisk.self))
        case "type_text":
            return .typeText(
                target: try enumValue("target", TypeTarget.self),
                app: optStr("app"),
                sessionID: optStr("session_id"),
                payload: try str("payload"),
                source: try enumValue("source", CommandSource.self, default: .verbatim))
        case "newline": return .newline
        case "clear_typed": return .clearTyped
        case "submit": return .submit(app: optStr("app"), sendPhrase: try str("send_phrase"))
        case "press_keys": return .pressKeys(keys: try str("keys"))
        case "scroll":
            return .scroll(
                direction: try enumValue("direction", ScrollDirection.self),
                amount: try enumValue("amount", ScrollAmount.self, default: .small))
        case "menu_command": return .menuCommand(item: try str("item"), menu: optStr("menu"))
        case "click_element": return .clickElement(name: try str("name"), near: optStr("near"))
        case "focus_text_box": return .focusTextBox(app: optStr("app"))
        case "describe_screen": return .describeScreen
        case "look_again": return .lookAgain
        case "rewrite_draft": return .rewriteDraft(text: try str("text"))
        case "start_dictation":
            return .startDictation(
                target: try enumValue("target", TypeTarget.self, default: .focused),
                app: optStr("app"),
                sessionID: optStr("session_id"),
                text: optStr("text"))
        case "system_volume":
            let level = (input["level"] as? NSNumber)?.intValue
            return .systemVolume(action: try enumValue("action", VolumeAction.self), level: level.map { min(100, max(0, $0)) })
        default:
            throw ParseError.unknownTool(name)
        }
    }
}
