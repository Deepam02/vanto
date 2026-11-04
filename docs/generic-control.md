# Vanto: controlling any app without per-app code

Question (4 Nov): how do we control every app and website (click things, focus boxes, zoom,
switch windows, run terminal commands you can't remember) without hard-coding each one?

## Short answer

Use what macOS already exposes for every app, in three layers, cheapest first:

1. **Menus.** Every Mac app lists its commands in the menu bar, with their shortcuts.
   "Zoom out" in Figma, "Duplicate tab" in Chrome and "New window" anywhere are all menu items.
   Reading the front app's menu bar over Accessibility and pressing an item by name covers
   most "do X in this app" requests with no per-app code.
2. **The accessibility tree.** Buttons, links, tabs and text fields in the front window,
   numbered and named, the way macOS Voice Control's "Show numbers" works. The router picks
   one by number and Vanto presses it, focuses it or sets its value. This covers:
   - native apps;
   - Electron apps (Slack, Claude, Cursor), once `AXManualAccessibility` is set on them;
   - web pages in Chrome, once Chrome's renderer accessibility is on.
3. **Screen agent (slow, rare).** For canvases and badly labelled apps, Claude's computer use
   toolset looks at a screenshot and clicks, in a loop, and Vanto checks the result after
   each step. It runs only when layers 1–2 can't do it, and the HUD shows it working.
   This is the "don't reduce the time, add abilities" path.

The fast commands we have today (apps, tabs, terminals, typing) stay as they are.
The new layers sit behind them.

## What each layer needs, and the evidence

### 1. Menus
- **Read:** `AXMenuBar` → `AXMenuBarItem` → `AXMenu` → `AXMenuItem`, with title, enabled
  state and shortcut (`AXMenuItemCmdChar` / `AXMenuItemCmdModifiers`). Press with
  `AXPress`. Voice Control numbers system menus the same way, without being asked.
- **Router:** gets a compact list for the front app only ("View › Zoom Out ⌘−").
  It is built when the front app changes and cached per app.
- **Covers:** zoom in Figma, most "can you …" in any app, and the `press_keys` failures
  ("Unknown keys: cmd+minus"), because the menu item is pressed directly.

### 2. Accessibility elements
- **Pattern:** collect only visible, interactive elements, give each an index valid for that
  snapshot only, and let the model answer with the index. This is how browser-use handles
  web pages ([browser-use DOM extraction][bu]) and how macOS agents such as
  [macOS-MCP][mcp] and [AXTerminator][axt] handle apps: accessibility tree first,
  screenshots only when it's missing.
- **Electron:** set `AXManualAccessibility` on the app element and its tree appears. This is
  documented by Electron for assistive tools ([Electron accessibility][el]). It fixes "Couldn't
  find a chat box in Slack" and "No text field is focused" in Claude.
- **Chrome web pages:** Chromium builds the web accessibility tree only once it sees
  assistive technology, detected through `AXEnhancedUserInterface` on the app
  ([Chromium accessibility overview][cr]). After that, links like "Conversations" on the
  Blooio dashboard are ordinary `AXLink` elements.
  - Spike first: setting `AXEnhancedUserInterface` is known to slow some apps and upset
    window-moving tools.
  - The alternative is a Chrome extension (reliable DOM access), but it means an install per
    profile.
- **Check after acting:** after a press, re-read the focused element or window title to
  confirm something changed ([the diff after the click][diff]). This is the same "verify
  before reporting success" rule the executors already follow.
- **Tools:**
  - `ui_press(n)`;
  - `ui_focus(n)` ("focus the text box");
  - `ui_set_text(n, …)`;
  - `scroll(direction: left|right|up|down)`, which pans the Figma canvas.
  To keep fast commands fast, the element list is not sent on every call: the router calls
  `look(…)` when it needs it, and gets the list back in the same reply loop.

### 3. Screen agent
- **Toolset:** Claude's `computer_toolset_20260801` works with Haiku 5.5, Sonnet 5.5 and
  Opus 5.5 with no beta header. It provides screenshot, zoom, click, type, key, scroll and
  wait, and lets the model batch several actions per reply ([computer use docs][cu]).
- **Cost:**
  - each screenshot is ~1,000–1,800 input tokens;
  - a Screen Recording permission is needed;
  - each step takes seconds.
- **Use:** only on request ("figure it out", "do it for me") or when layers 1–2 return
  nothing. Send the element list along with the screenshot so it clicks by name when it can.
- **Safety:** the same rules as now apply. Nothing is sent, deleted or run without your yes,
  and the HUD shows every step.

## Web apps (Figma in Chrome, dashboards)
In a browser the menu bar is Chrome's, so layer 1 doesn't apply. A web app is covered by:
- **Its own shortcuts.**
  - Figma on the web: `-` zooms out, `=` zooms in, Shift+1 zooms to fit.
  - The model already knows common apps' shortcuts. On 4 Nov it chose `-`, and it failed
    only because the key parser didn't know `-`.
- **Its page elements (layer 2).** Figma's main menu, toolbar, Layers panel and share button
  are DOM elements. Once Chrome's accessibility is on, they appear in the numbered list.
- **Panning** is a scroll over the canvas: left/right for sideways.
- **Canvas contents** (shapes inside a Figma frame) are pixels with no accessibility. Only
  the screen agent (layer 3) can click those.

## Terminals: "I don't remember the command"
- **Composing commands** already works (`terminal_run`, source: composed, risk label,
  spoken confirmation for anything that isn't read-only). Add:
  - **Type it first, then ask.** Paste the composed command into the terminal without
    Enter, and the HUD asks "Run it?". "Yes" presses Enter. You see exactly what will run.
  - **Steps.** "Set up a new React app in a folder called demo" becomes 2–4 commands, each
    shown and confirmed in turn.
  - **Context.** Give the router the last ~30 lines of the selected terminal (Terminal and
    iTerm2 expose a tab's contents over AppleScript), plus its cwd and git branch. Then
    "fix that error", "run it again" and "what does this mean" have something to work on.
- **Split screen and full screen.**
  - Raising a window that sits in another full-screen Space isn't dependable over
    Accessibility; scripting forums report `AXRaise` failing there ([MacScripter][ms]).
  - For terminals we don't need focus at all: Terminal and iTerm2 can type into a specific
    tab by ID over AppleScript, wherever it is.
  - For other apps, activate the app (macOS switches to its Space), then raise the window,
    then check which window is actually in front.

## Where this leaves the plan
- **Phase 2 (reliability)** stays first.
- **Phase 3** becomes the generic layer, menus plus elements. It replaces the separate items
  for "focus the text box", "click by name", Figma zoom and pan, "what can I do here", and
  the Slack and Claude typing fixes.
- **Then voice dictation and draft editing.**
- **Then the terminal assistant** (type, then confirm; steps; context).
- **The screen agent comes last,** once we see what layers 1–2 can't reach.

## Not copying code
The project allows only FluidAudio and KeyboardShortcuts as dependencies, and the Mac-side
code is Swift. The projects above are references for patterns, not libraries to add.
[Peekaboo][pk] (Swift, accessibility "UI map" plus screenshots) is the closest in spirit.

[bu]: https://theneuralbase.com/browser-use/learn/intermediate/extract-semantic-elements/
[mcp]: https://github.com/CursorTouch/MacOS-MCP
[axt]: https://docs.rs/crate/axterminator/latest/source/CLAUDE.md
[el]: https://electronjs.org/docs/latest/tutorial/accessibility
[cr]: https://chromium.org/developers/design-documents/accessibility
[diff]: https://macos-use.dev/t/macos-accessibility-tree-agents
[cu]: https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool
[ms]: https://www.macscripter.net/t/automating-split-view-on-mac
[pk]: https://glama.ai/mcp/servers/openclaw/Peekaboo
