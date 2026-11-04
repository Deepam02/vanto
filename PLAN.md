# Vanto plan: from first test to daily driver

Built for anyone; Deepam is the first test user. Setup and permissions are parked for now.
Source: every real session so far, from `~/Library/Logs/VoiceCommand/commands.jsonl`:
- 3 Nov (two sessions): 42 commands.
- 4 Nov (seven sessions): 51 commands. 29 came back "ok", but 9 of those were "I can't do that" or "I'm not sure".

## What went wrong, and why

| Said | Result | Cause in the code |
|---|---|---|
| A long prompt with ums and short pauses | "Didn't catch that", every word lost | Routing fired at a 0.64 s pause ("…Uh and like"). The router returned no tool call twice, and the stream ended with no stop reason and no usage, so the real error isn't logged. `SessionController.route` then calls `buffer.consume` on any router error, which throws the dictation away. The router also has `maxTokens = 400` and copies dictated text into `type_text.payload`, so long dictation can't fit anyway. |
| "go to context.dev" ×2, "go to LinkedIn" | "Couldn't switch to that tab" | Both tabs were in the second Chrome window (the other profile). `switchTab` loops over tabs with one Apple event each, under a 1.5 s timeout. Then `activateChrome` brings Chrome's front window forward, not the tab's window. The real AppleScript error isn't logged. |
| "switch to the other profile / window", "go to the Deepam profile" ×3 | "Can't switch profiles yet" | Not built. The snapshot has no idea which profile a window belongs to. |
| (implicit) | Tabs past #40 are invisible | `DesktopSnapshot.maxTabs = 40`, listed in window order. With messy tabs, the router never sees the one you mean, so it opens a duplicate. |
| "open a different terminal" → "run ls" ×2 | "No terminal session open" | The only Terminal tab was running Claude Code. The new tab wasn't found in the next snapshot (the 0.5 s AppleScript timeout is the likely cause), and the router made up session IDs. |
| "draft a Slack message…" | "Couldn't find a chat box in Slack" | Slack (Electron) hides its accessibility tree unless `AXManualAccessibility` is set. |
| "close tabs", "close Slack", "what can you do here?" | Not supported, or a generic answer | Not built. |

### Second session (3 Nov, later): 13 commands
- **Tab switching failed 5 more times out of 5** (Netflix ×2, Twitter, context.dev). Root cause found: Chrome's scripting dictionary declares tab and window `id` as **text**. `switchTab` compares `id of t is 1051909715` (a number), so it never matches. The loop runs off the end and activates the **last** tab in that window, and the check fails. `closeTab` (`whose id is <number>`) has the same bug. Switching to the other Chrome *window* (`focus_window`) worked.
- **"Go to X" asked which site; "Go to Xcode" was a mishearing of "X.com".** Common sites need aliases (X = x.com = Twitter), and the speech vocabulary needs common site names.
- **Netflix audio was picked up as speech.** The mic hears whatever the Mac is playing. Fix: turn on Apple's voice processing (echo cancellation) on the input, so the Mac's own playback is cancelled.
- **"What are the options on Netflix? Click this."** Reading and clicking things on a web page isn't built. It goes on the later list.
- "What tabs are open?" worked: it named 10 and said "18 more".

### Seven sessions on 4 Nov, after phase 1: 51 commands
**What phase 1 fixed.** Tab switching works now (context.dev and Blooio, 2 out of 2), and so does switching to the other Chrome window. Hold-Fn dictation was never used: there are no dictation entries in the log.

**What's still broken:**
- **The router sometimes returns nothing at all**: "Didn't catch that (events: 0, stop: none)", 5 times. Each time, both the first try and the retry returned zero events. It happened on "Okay.", on "Yeah." and on three long prompts. Two cases on 3 Nov have the same signature, so phase 1 didn't cause it. The log still can't say why: the HTTP status and raw response aren't recorded.
- **Commands got about 0.9 s slower.** The median time from the end of speech to the router starting went from 0.80 s (3 Nov, 42 commands) to 1.67 s (4 Nov, 51 commands). Speech end to done went from 2.6 s to 3.4 s. No setting was changed. The main suspect is the new echo cancellation (voice processing buffers audio and can hold the voice detector in "speech" for longer).
- **A long prompt into Claude desktop was lost again.** It failed with events: 0 three times. Then `type_text` failed with "No text field is focused" (Claude is an Electron app and doesn't report its text box), and the words were consumed on that failure. You had asked it to "wait for me" while you wrote.
- **Terminal commands, 9 rejected.** The router passes a *window* ID (`w1`) as the terminal session, and the policy then finds no free shell. It worked as soon as you focused a window yourself ("in this window, run ls" → `terminal:ttys001`). Opening a terminal by voice then running a command still fails.
- **Shell commands are misheard.** "ls" became "Ellis" and "L S", and "pwd" became "TWD". The router then asked what "Ellis command" means.
- **"Zoom out" in Figma.** `press_keys` rejected `cmd+minus` and `-` as unknown keys: the key parser has no minus, plus or equals.

**New things you wanted that don't exist:**
- **Edit what was typed:** "improve its English", then "edit the previous message". The draft was cleared, and the rewrite was refused because typed text must match your words exactly. The message was gone.
- **Focus a text box:** "Can you focus on the text box?" in Claude desktop.
- **Control more of each app** (your words: "I want you to control even more functions on each app"):
  - pan the Figma canvas left or right;
  - zoom;
  - "go to Conversations / Limits on this tab" (links inside a web page).
- **"Write a message… it will take me a while, wait for me… send it."** That is dictation started by voice. Hold-Fn exists, but you reached for voice.
- **"What can you do on this tab?"** It gave the same generic answer as on 3 Nov.

## Decisions

### 0. Fix tab IDs (hotfix, first)
Compare Chrome IDs as text. Find the window and tab inside one script, using `id of every tab` (one Apple event), and fix `closeTab` the same way.

### 0b. Ignore the Mac's own audio
Turn on voice processing on the mic input (`AVAudioInputNode.setVoiceProcessingEnabled`), so video and music playing on the Mac aren't transcribed. Leave a setting to turn it off if it hurts accuracy.

### 1. Never lose dictated words
- A router error never consumes the buffer. The text stays in the HUD with "Didn't route that. Say it again, or 'type it'."
- Log the HTTP status, stop reason and raw event count for every failed route, so we can see the next failure instead of guessing.

### 2. Dictation is its own mode, not a router job
- **Two ways in.** Hold a dictation key (default: hold Right ⌥), or say a trigger ("type…", "draft a prompt…", "write…", "tell Claude Code…").
- **The app types the words itself.** The LLM only decides where they go. Payloads are no longer copied through the router, so there's no token limit and no paraphrasing.
- **Pauses.** While dictating, pauses never end the draft and um/uh never trigger routing. Only these end dictation:
  - releasing the key;
  - "send" / "done" / "stop dictating";
  - 4 s of silence (a setting).
- **Target.**
  - The app you named.
  - Otherwise, "this" or no app means the focused text field.
  - If nothing editable is focused, the text goes to the clipboard and the HUD says so.
- **Light clean-up, on by default.** Remove fillers, fix punctuation and capitals, keep every content word. Can be switched off for verbatim.
- **Goal:** usable in place of Fluid Voice for prompting Claude Code.

### 3. One "places" list for navigation
- **Every destination becomes a place:**
  - an app window;
  - a Chrome window, with its profile;
  - a Chrome tab;
  - a terminal tab, with cwd folder, running program (claude, `npm run dev`…) and title.
- **All tabs, not 40.** Tabs are matched locally on title, URL host and path before the router call. The router sees the top matches for this utterance, plus the active tab of each window.
- **Chrome profiles.**
  - The names come from `~/Library/Application Support/Google/Chrome/Local State` (`Deepam`, `boringworkflows.ai`).
  - Each window gets its profile by matching its accessibility title, which ends in "- Google Chrome - <profile>" when several profiles are open (to check on device).
  - Aliases are set in Settings: "work" → boringworkflows.ai, "personal" → Deepam.
- **Terminals.**
  - Terminal.app cwd and the foreground program come from `ps`/`lsof` on each tab's tty.
  - A tab opened by voice becomes the default shell for the session.
  - Unknown session IDs are rejected, not guessed.
- **Relative moves:** "the other window", "next/previous tab", and "go back" (to the previous place, in recently-used order).
- **Switching.**
  - Set the tab index directly from the snapshot, with no per-tab loop.
  - Raise that exact window over accessibility, then activate Chrome.
  - Timeout of 3 s, with the real error logged.

### 4. When to switch to an existing tab and when to open a new one
1. **Switch** when a tab matches what you named, in any window or profile:
   - prefer the current profile first, then the most recently used;
   - if several match, take the most recent and offer "next" in the HUD.
2. **Open a new tab** only when:
   - nothing matches;
   - you say "new tab", "another", or "open a fresh…";
   - it's a search ("search…", "look up…").
3. **Where a new tab opens:**
   - in the profile you named;
   - else in the profile where you last used that site;
   - else in the current window's profile.
4. "Here" or "in this tab" navigates the current tab.

### 5. Small missing commands
- **Close:** "close this tab", "close the LinkedIn tabs" (always shows the count first), "close Slack" (quit; the app asks about unsaved work itself).
- **"What can you do here?"** answers for the app in front, with 3–4 examples using real names from the snapshot.
- **Slack and other Electron apps:** set `AXManualAccessibility` before looking for the text box. If there's still none, focus the window and paste.

### 6. Reliability first (from 4 Nov)
- **Empty router replies.**
  - Record the HTTP status, the number of SSE lines and the first 300 bytes of the body for every route that ends without a tool call.
  - Retry on a fresh connection (new `URLSession` task, no reused HTTP/2 stream) before giving up.
  - Fix the cause once it shows up in the log.
- **Latency.**
  - Test echo cancellation on and off with the same phrases.
  - If it's the cause, turn voice processing on only while the Mac is actually playing audio (the output device reports when it's running), so commands are fast the rest of the time.
  - Target: back to ≤ 0.8 s from speech end to routing.
- **Typing never loses words.** When `type_text` can't find a text field, paste anyway and leave the text on the clipboard, as hold-Fn does. Never consume the words of a failed type.
- **Terminals.**
  - Resolve a window ID to that window's visible tab.
  - A tab opened by voice becomes the default shell.
  - Make the Terminal listing reliable: longer timeout, and keep the last good list if a refresh times out.
- **Spoken shell commands.** Boost `ls`, `pwd`, `cd`, `git`, `npm` in speech. Add a router rule for common mishearings ("Ellis", "L S" → `ls`; "TWD", "P W D" → `pwd`).
- **Keys.** The key parser learns `minus`, `plus`, `equals` and `-`/`=`, so "zoom out" → ⌘−.

### 7. Dictation started by voice
- "Write a message…", "type this…", "take a note…", "wait for me" enter the same dictation mode as holding Fn. From then on, every word is collected locally with no router call per pause, and the overlay shows "Dictating: say 'send it' or 'done'".
- **Ends on:**
  - "send it" (types, then sends);
  - "done" or "stop" (types, doesn't send);
  - 8 s of silence (types, doesn't send).
- **Target:** the app named, else the focused field.

### 8. Edit a draft by voice
- Allowed while a draft is open:
  - "improve the English";
  - "make it shorter";
  - "make it more polite";
  - "fix the typos".
- The model rewrites the text this app typed (and only that), and the rewrite replaces it in the field. It is never sent.
- Undo puts the original back. Only the draft can be rewritten, never other text on screen, so this is the one place composed text may be typed.

### 9. Act inside apps and pages
- **"Focus the text box / chat box"** focuses the main text input of the front app (reusing the chat-box finder, plus `AXManualAccessibility` for Electron).
- **"Click / go to X"** inside the front app or web page. Find a button, link or tab named X in the accessibility tree and press it. Chrome exposes web pages to accessibility, so "go to Conversations" on the Blooio dashboard works the same way.
- **"What can I do here?"** lists the 5–8 most useful named controls on screen, plus app-specific tips.
- **Per-app actions** come from an app-hints file:
  - Figma: zoom in, zoom out, zoom to fit, pan left/right/up/down (horizontal scroll);
  - Chrome page: back, forward, find on page.
  - New apps are added as data, not code.

## Order of work
Each phase ends with a build to try for a day, plus `swift run log-report`.

| Phase | What | Done when |
|---|---|---|
| 1 ✅ built 3 Nov, used 4 Nov | Decisions 0, 0b, 1, 2: tab ID fix, ignore Mac audio, never lose words, hold-Fn dictation, site aliases | Tab switching verified 4 Nov. Hold-Fn not tried yet. |
| 2 ✅ built 4 Nov, to try | Decision 6: empty replies, latency, typing fallback, terminals, spoken commands, keys. Also built early: phase 3's menus and elements, phase 4's voice dictation and draft editing, phase 5's type-then-confirm and terminal context | No "events: 0" errors in a day; speech end → routing ≤ 0.8 s; every 4 Nov terminal line works |
| 3 | Decision 9, built generically (`docs/generic-control.md`): the front app's menus plus numbered accessibility elements, with Electron and Chrome page accessibility switched on; focus, press, set text, scroll in any direction | "focus the text box", "go to Conversations on this tab", "zoom out" and panning in Figma all work with no app-specific code |
| 4 | Decisions 7–8: voice-started dictation, edit the draft | The 4 Nov Claude message lands intact and can be "improved" before sending |
| 5 | Terminal assistant: type the command first then confirm, multi-step tasks, the terminal's last lines as context | "make a folder called demo" types `mkdir demo`, waits for yes; "fix that error" sees the error |
| 6 | Decisions 3–5: one places list, Chrome profiles by name, all tabs, close and quit | Every navigation line from 3–4 Nov works; switches succeed ≥ 95% in the log |
| 7 | Screen agent (Claude computer use) for what layers 1–2 can't reach, on request | Decided after phase 3 shows what's left |
| 8 | Setup (parked): fewer permissions, Developer ID signing | Later |

Every failure from the logs gets added to the router's test set (`router-eval`) so it can't come back.
