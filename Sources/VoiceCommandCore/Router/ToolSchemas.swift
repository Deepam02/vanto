import Foundation

/// The one authoritative tool list (PRD build spec, amended by "Final review" point 1).
/// The JSON is static and serialised with sorted keys so the bytes never change between
/// calls and the prompt cache keeps working. Live IDs never appear here.
public enum ToolSchemas {
    public static let names: [String] = definitions.compactMap { $0["name"] as? String }

    /// Tool definitions as sent to the API, with `eager_input_streaming` and the cache
    /// breakpoint on the last tool.
    public static let definitions: [[String: Any]] = {
        let data = Data(rawJSON.utf8)
        guard var tools = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            fatalError("ToolSchemas.rawJSON is not valid JSON")
        }
        for i in tools.indices {
            tools[i]["eager_input_streaming"] = true
        }
        tools[tools.count - 1]["cache_control"] = ["type": "ephemeral"]
        return tools
    }()

    static let rawJSON = """
    [
      {"name": "wait_for_more", "description": "The request is unfinished or the person is still talking. Nothing runs; keep listening.", "input_schema": {"type": "object", "properties": {}}},
      {"name": "ignore", "description": "The latest speech is not a command (chatter, talking to someone else, filler). It is dropped.", "input_schema": {"type": "object", "properties": {}}},
      {"name": "say", "description": "Show one short sentence in the HUD when nothing else fits or the request cannot be done.", "input_schema": {"type": "object", "properties": {"message": {"type": "string"}}, "required": ["message"]}},
      {"name": "end_session", "description": "Stop listening and end the voice session.", "input_schema": {"type": "object", "properties": {}}},
      {"name": "confirm_pending", "description": "The person approved the held action (e.g. 'yes, run it').", "input_schema": {"type": "object", "properties": {}}},
      {"name": "cancel_pending", "description": "The person rejected the held action.", "input_schema": {"type": "object", "properties": {}}},
      {"name": "undo_last", "description": "Reverse the last reversible action (refocus the previous app, close an opened tab, clear typed text).", "input_schema": {"type": "object", "properties": {}}},
      {"name": "open_app", "description": "Launch or bring an app to the front.", "input_schema": {"type": "object", "properties": {"app": {"type": "string", "description": "bundle ID from context, or app name to launch"}}, "required": ["app"]}},
      {"name": "focus_window", "description": "Bring one specific window to the front, by window ID from desktop_context.", "input_schema": {"type": "object", "properties": {"window_id": {"type": "string"}}, "required": ["window_id"]}},
      {"name": "browser_switch_tab", "description": "Switch to an open Chrome tab, by tab ID from desktop_context.", "input_schema": {"type": "object", "properties": {"tab_id": {"type": "string"}}, "required": ["tab_id"]}},
      {"name": "browser_open_url", "description": "Open a URL in Chrome, in a new tab or the current one.", "input_schema": {"type": "object", "properties": {"url": {"type": "string"}, "new_tab": {"type": "boolean"}}, "required": ["url"]}},
      {"name": "browser_new_tab", "description": "Open an empty new Chrome tab.", "input_schema": {"type": "object", "properties": {}}},
      {"name": "browser_close_tab", "description": "Close a Chrome tab, by tab ID from desktop_context.", "input_schema": {"type": "object", "properties": {"tab_id": {"type": "string"}}, "required": ["tab_id"]}},
      {"name": "browser_navigate", "description": "Reload, go back or go forward in the active Chrome tab.", "input_schema": {"type": "object", "properties": {"action": {"enum": ["reload", "back", "forward"]}}, "required": ["action"]}},
      {"name": "browser_search", "description": "Search the web for a query in a new Chrome tab.", "input_schema": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}},
      {"name": "terminal_focus", "description": "Bring a terminal session to the front, by session ID from desktop_context.", "input_schema": {"type": "object", "properties": {"session_id": {"type": "string"}}, "required": ["session_id"]}},
      {"name": "terminal_new", "description": "Open a new terminal tab, optionally in a directory.", "input_schema": {"type": "object", "properties": {"cwd": {"type": "string"}}}},
      {"name": "terminal_run", "description": "Run a shell command in a terminal session. Label where the command came from and how risky it is.", "input_schema": {"type": "object", "properties": {"session_id": {"type": "string"}, "command": {"type": "string"}, "source": {"enum": ["verbatim", "composed"]}, "risk": {"enum": ["read_only", "changes_files", "destructive", "network_or_deploy"]}}, "required": ["session_id", "command", "source", "risk"]}},
      {"name": "type_text", "description": "Type text without sending it: into the focused field, an app's chat box, or a terminal session (e.g. a prompt for Claude Code).", "input_schema": {"type": "object", "properties": {"target": {"enum": ["focused", "chat_box", "terminal"]}, "app": {"type": "string"}, "session_id": {"type": "string"}, "payload": {"type": "string", "description": "copied verbatim from the transcript"}}, "required": ["target", "payload"]}},
      {"name": "newline", "description": "Insert a line break in the open draft without sending it.", "input_schema": {"type": "object", "properties": {}}},
      {"name": "clear_typed", "description": "Remove the text this app typed into the current draft.", "input_schema": {"type": "object", "properties": {}}},
      {"name": "submit", "description": "Send what was typed. Only when the person explicitly asks to send.", "input_schema": {"type": "object", "properties": {"app": {"type": "string"}, "send_phrase": {"type": "string", "description": "the person's exact words asking to send, copied from the transcript"}}, "required": ["send_phrase"]}},
      {"name": "press_keys", "description": "Press a keyboard shortcut in the front app.", "input_schema": {"type": "object", "properties": {"keys": {"type": "string", "description": "e.g. cmd+k, enter, escape"}}, "required": ["keys"]}},
      {"name": "scroll", "description": "Scroll the front window.", "input_schema": {"type": "object", "properties": {"direction": {"enum": ["up", "down"]}, "amount": {"enum": ["small", "page"]}}, "required": ["direction"]}}
    ]
    """
}
