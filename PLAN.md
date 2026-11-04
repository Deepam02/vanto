# Plan: from first test to daily driver

Built for anyone; Deepam is the first test user. Setup and permissions are parked for now.
Source: the first real session (3 Nov 2026, `~/Library/Logs/VoiceCommand/commands.jsonl`):
31 commands, 19 worked, 9 failed or weren't supported, 3 were filler.

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

## Order of work
Each phase ends with a build to try for a day, plus `swift run log-report`.

| Phase | What | Done when |
|---|---|---|
| 1 ✅ built 3 Nov, to try | Decisions 0, 0b, 1, 2: tab ID fix, ignore Mac audio, never lose words, dictation mode, site aliases (X = Twitter) | A 60 s rambling prompt with pauses lands intact in Claude Code and in the focused field |
| 2 | Decisions 3–4: places, profiles, terminals, tab rules | Every navigation line from the 3 Nov log works; tab, window and profile switches succeed ≥ 95% in the log |
| 3 | Decision 5: close, quit, help, Slack | The 3 Nov "not supported" lines work |
| 4 | Setup (parked): fewer permissions, Developer ID signing | Later |

Every failure from the 3 Nov log gets added to the router's test set (`router-eval`) so it can't come back.
