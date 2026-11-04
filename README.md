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
| "clean up the build folder" | Proposes `rm -rf build` and **waits for "yes, run it"** |
| "open slack, no wait, discord" | Opens Discord only |

**Safety rules that always hold:** silence never sends; a send needs your spoken word after
the text; a terminal command runs straight away only if you dictated it word for word, it's
read-only, and it's not on the deny-list (rm, git push, deploys, …) — everything else waits for
"yes"; `sudo` never runs; nothing is ever typed into a password field; text it types is copied
from your own words, never paraphrased; screen text (tab titles, window titles) is treated as
untrusted data.

### Settings

Commit delay (default 450 ms after you stop talking), session idle timeout (20 s – 5 min),
"Thinking pauses" (filler words and trailing "and"/"so" always wait), built-in mic (default
on, keeps AirPods in high-quality mode), Fn on/off, fallback chord.

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

## Router eval

```sh
ANTHROPIC_API_KEY=$(security find-generic-password -s VoiceCommand -a anthropic-api-key -w) \
  swift run -c release router-eval            # --filter id, --repeat N, --verbose
```

Runs `Tools/router-eval/golden-set.json` (44 cases) against the API and prints accuracy and
p50/p90 time to first tool call. Acceptance is ≥ 90% accuracy (last result: 98.5%,
p50 ~760 ms). If your API key isn't scoped to a workspace, also set `ANTHROPIC_WORKSPACE_ID`
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
Tests/                      unit tests (scripts/test.sh)
Tools/                      golden set, scripted executor run
Vendor/KeyboardShortcuts/   vendored, patched for a CLT-only build
```
