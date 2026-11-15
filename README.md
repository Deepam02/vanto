# Vanto

Vanto is a voice-first macOS menu-bar app. Tap **Fn/🌐**, speak naturally, and it switches apps and
Chrome tabs, runs terminal commands, and types prompts into Claude Code, Cursor, ChatGPT,
Claude desktop and Slack — sending only when you say so.

Speech is transcribed on your Mac (Parakeet via FluidAudio on the Neural Engine). Only the
routing call goes to the Claude API (Claude Haiku 5.5), with a text snapshot of your desktop.
The spec is `PRD.md`; choices it left open are in `DECISIONS.md`; status is in `PROGRESS.md`;
what's next is in `PLAN.md`.

**Name.** Vanto is the product name. The code still uses its working name, VoiceCommand: the
app builds as `VoiceCommand.app`, and the bundle ID, Keychain item, signing identity and log
and settings folders below all say VoiceCommand. Renaming those is a separate change, because
a new bundle ID means granting every permission again.

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon
- Xcode **or** just the Command Line Tools (`xcode-select --install`), Swift 6
- An Anthropic API key
- About 1.2 GB of disk for speech models (downloaded once, on first launch)

## Build

```sh
./build.sh            # release build → dist/VoiceCommand.app (signed)
./build.sh --open     # build, quit any running copy, launch
./scripts/test.sh     # unit tests
```

**Signing.** `build.sh` signs with `$SIGN_IDENTITY`, else your Apple Development identity,
else "VoiceCommand Local Signing", else ad-hoc. With ad-hoc signing macOS treats every rebuild
as a new app and asks for Accessibility and Input Monitoring again. If you have no Apple
Development certificate, run this once and rebuild:

```sh
./scripts/make-signing-identity.sh   # self-signed code-signing identity in your login keychain
```

Copy `dist/VoiceCommand.app` to `/Applications` if you like (grant permissions to that copy).

## Setup (about 2 minutes)

1. **Launch** `dist/VoiceCommand.app`. A mic icon appears in the menu bar and the
   Permissions window opens. Speech models start downloading (progress bar at the top of the
   screen).
2. **API key.** Either paste it in **Settings** (menu bar → Settings…), or store it from a
   terminal so it never appears on screen:
   ```sh
   security add-generic-password -U -s VoiceCommand -a anthropic-api-key -w
   ```
   The first time the app reads it, macOS asks; click **Always Allow**.
3. **Grant each permission** in the Permissions window until every row is green:

   | Permission | Why | How |
   | --- | --- | --- |
   | Microphone | Hearing you (only while a session is open) | Click Grant |
   | Accessibility | Focusing windows, finding text boxes, typing, keys | Click Grant, switch VoiceCommand on in System Settings |
   | Input Monitoring | The Fn/🌐 hotkey | Click Grant, switch it on, then quit and reopen VoiceCommand |
   | Automation: Chrome, Terminal, iTerm2, Ghostty | Tabs and terminal sessions | Click Allow for each installed app (it must be running) |
   | Screen Recording | Not needed | — |

4. **Globe key.** System Settings › Keyboard › "Press 🌐 key to" → **Do Nothing**, otherwise
   macOS also opens the emoji picker or dictation. (The Permissions window has a button.)
5. **Chrome:** nothing else to enable. "Allow JavaScript from Apple Events" stays **off**.

The fallback hotkey **⌃⌥Space** always works, including when Cursor's Secure Input bug
disables the Fn key. Change it in Settings.

## Using it

- **Tap Fn** (or ⌃⌥Space) to start a session. The HUD at the top shows what it hears.
- **Hold Fn** to dictate: everything you say while holding it is typed into the focused field
  when you let go. Nothing is sent, and pauses or "um"s can't cut it short.
- Speak commands one after another; pause as long as you like mid-thought.
- **Tap Fn again**, say "that's all", or stay silent for 20 s to end the session.
- **"Pause listening"** mutes without ending; **"resume"** brings it back.

| Say | What happens |
| --- | --- |
| "switch to cursor" | Cursor comes to the front |
| "go to the github tab" | Chrome switches to the matching tab |
| "open the stripe dashboard in a new tab" | Opens dashboard.stripe.com |
| "close this tab" / "undo that" | Closes it / reopens it |
| "ask claude code why the build is failing" | Types the question into the terminal running Claude Code. **Not sent.** |
| "… and also check the logs" | Appends to the same draft |
| "send it" / "enter it" / "ship it" | Sends the draft |
| "scratch that" / "new line" | Removes only what it typed / inserts a line break |
| "ask chatgpt how do I center a div" | Finds ChatGPT's message box and types it |
| "run npm test" | Runs it in your plain shell session (dictated, read-only → runs) |
| "clean up the build folder" | Types `rm -rf build` into the terminal **without pressing Enter**, and waits for "yes" ("no" takes it back out) |
| "run the command that shows all the folders" | Writes the command for you (`ls -d */`); runs once you say yes |
| "open a terminal" → "run ls" | The terminal it opened is where commands go |
| "fix that error" (terminal in front) | It can read the terminal's last lines (secrets masked) |
| "open slack, no wait, discord" | Opens Discord only |
| "zoom out" / "new window" / "export" | Runs that command from the front app's menu bar, in any app |
| "go to Conversations on this tab" | Clicks a button, link or tab by its name, in any app or web page |
| "focus the text box" | Puts the cursor in the app's message box |
| "what can you do here?" | Lists the menus and buttons it can see |
| "move the canvas left" | Scrolls sideways (pans Figma) |
| "improve the English" / "make it shorter" | Rewrites the draft it typed; never sends; "undo" brings back the original |
| "write a message, wait for me" | Dictation by voice: everything you say is collected until "send it" or "done" |

### Just talking: dictation without a trigger

With a text box focused, plain speech is typed: no "write this down" first. A short gate on
your Mac decides each utterance before the router sees it. Certain commands ("switch to
Chrome", "can you open my calendar") go to the router as before. Certain dictation (14 words
or more of prose into a text box or an AI prompt, no "can you") is typed. Everything in
between goes to the router, which can choose `dictate` or `keep` too.

- **Where it types and how.** Into Claude Code / Codex sessions, Claude, ChatGPT, Cursor's
  chat, Notes and editors it types as you go, mending pauses mid-sentence. Into message boxes
  (Slack, Messages, WhatsApp, Mail/Gmail, X, LinkedIn, Discord, Teams) it pastes once you
  pause, so a half-written message never sits there. It also pastes on a pause whenever the
  router made the call or media is playing. Hold Fn still types on release.
- **Nothing is sent by itself.** Only "send it" (or "send this message") at the end sends.
  "Done" or "stop dictating" ends a run without sending.
- **Background audio.** With a video playing, speech without a command cue is kept silently,
  not typed.
- **Settings → "Type what I say when I'm not giving a command"** (on by default). Off: the
  router decides, as before, but words are still kept, never dropped.

**Fixing a wrong guess:**

| Say | What happens |
| --- | --- |
| "that was a command" | Removes what it just typed and runs those words as a command |
| "type that instead" / "no, type that" | Undoes the last action if it can, then types its words |
| "scratch that" | Removes the last typed chunk (kept as discarded) |
| "never mind" / "cancel dictation" | "Never mind" erases a run under 3 s old (an older run stops and its waiting words are kept); "cancel dictation" always erases |
| "type it" / "paste it" / "type the one about the deck" | Types the newest kept words, or the ones about X |
| "copy it" | Copies the newest kept words |
| "what did you keep?" | Shows the Kept list in the HUD |
| "Vanto, …" | Always a command, even mid-dictation |

**Speech history and Kept.** Every utterance ends up acted on, typed, kept (noise, unclear,
nowhere to type, a failure, the session ended) or discarded by you, never silently dropped.
Each is one line in `~/Library/Application Support/VoiceCommand/history.jsonl`: local only,
never sent, no expiry. The menu bar's **Kept** submenu shows the last 10 kept items; click one
to copy it. Settings → **Clear speech history…** deletes the file.

**Safety rules that always hold:** silence never sends; a send needs your spoken word after
the text; a terminal command runs straight away only if you dictated it word for word, it's
read-only, and it's not on the deny-list (rm, git push, deploys, …) — everything else waits for
"yes"; `sudo` never runs; nothing is ever typed into a password field; text it types is copied
from your own words, never paraphrased; screen text (tab titles, window titles) is treated as
untrusted data; clicking or choosing a menu item named "Delete", "Send", "Pay" and similar
waits for "yes".

### Settings

Commit delay (default 450 ms after you stop talking), session idle timeout (20 s – 5 min),
"Thinking pauses" (filler words and trailing "and"/"so" always wait), built-in mic (default
on, keeps AirPods in high-quality mode), Fn on/off, fallback chord, "Type what I say when I'm
not giving a command" (default on), and "Clear speech history…".

`~/Library/Application Support/VoiceCommand/AppHints.json` controls how each app's chat box is
found (Cursor = ⌘L if not already focused; Claude/ChatGPT/Codex = bottom text area; Slack =
"Message…" box), its send and newline keys, and the privacy denylist (apps whose titles are
never sent).

## Logs and measurement

Every routed utterance is one JSON line in `~/Library/Logs/VoiceCommand/commands.jsonl`
(timings from end of speech, transcript, tool calls, safety decisions, results, undo/
corrections). Turn it into the PRD's success-criteria table:

```sh
swift run log-report
```

Each record also says how the intent gate decided (`intent`), what was focused (`focusKind`),
whether media was playing, and where the words went (`disposition`); each disposition is its
own `disposition` line by segment. log-report adds words lost (segments without a disposition:
must be 0), typed-then-"that was a command" (false dictation), "type that instead" (false
command), and kept items later typed or copied back.

## Intent eval

```sh
swift run -c release intent-eval     # --verbose lists every decision
```

Runs the local intent gate (no API calls) over `Tools/intent-eval/labelled-utterances.json`:
every logged utterance, hand-labelled command / dictation / mixed / background, plus 61
persona examples (emails, Slack replies, notes, Claude Code prompts, commands). It prints
per-class precision and recall in four contexts (a Slack box, a Claude Code prompt, nothing
focused, media playing) and fails if any command is certain dictation, any dictation a certain
command, or any background speech is typed.

## Router eval

```sh
ANTHROPIC_API_KEY=$(security find-generic-password -s VoiceCommand -a anthropic-api-key -w) \
  swift run -c release router-eval            # --filter id, --repeat N, --verbose
```

Runs `Tools/router-eval/golden-set.json` (134 cases, including the `dictate_keep` group) against
the API and prints accuracy per group and p50/p90 time to first tool call. Being an LLM eval,
the bar is ≥ 98% overall, not 100% (last result, --repeat 3: 98.3%, p50 ~920 ms). If your API key isn't scoped to a workspace, also set `ANTHROPIC_WORKSPACE_ID`
(and the Workspace ID field in Settings).

## Executor check without the router (M4)

Open Chrome (with a GitHub tab), Terminal (one tab running `claude`, one plain shell), Slack
and Claude desktop, then:

```sh
open dist/VoiceCommand.app --args --action-script "$PWD/Tools/action-script/golden-actions.json"
```

It runs each step through the real safety policy and executors, opens a report, and quits.
The script types test text and clears it again; it never sends.

## Troubleshooting

- **Fn does nothing:** Input Monitoring is off, or the tap was disabled (the HUD says so). Use
  ⌃⌥Space; re-grant Input Monitoring and reopen the app.
- **"Couldn't find a chat box in X":** focus the box once by hand and say it again; the app
  then uses the focused field. Add a row to `AppHints.json` for new apps.
- **Chrome/terminal actions fail:** Automation permission for that app (System Settings ›
  Privacy & Security › Automation › VoiceCommand).
- **Permissions reset after a rebuild:** you're ad-hoc signed; see Signing above.

## Layout

```
Sources/VoiceCommandCore/   Foundation-only: router (prompt, tool schemas, SSE client),
                            safety policy, transcript buffer, logging, eval grader
Sources/VoiceCommand/       the app: App/ (menu bar, settings, permissions, hotkeys),
                            Audio/, Context/, Executor/, Session/, UI/
Sources/router-eval/        golden-set runner        Sources/log-report/  log → criteria table
Sources/intent-eval/        local intent gate on labelled speech
Tests/                      unit tests (scripts/test.sh)
Tools/                      golden set, labelled utterances, scripted executor run
Vendor/KeyboardShortcuts/   vendored, patched for a CLT-only build
```
