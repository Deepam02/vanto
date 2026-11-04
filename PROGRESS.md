# Vanto: progress

Status of each PRD milestone. "Verified" means checked on this machine by me; "needs you"
means it can only be accepted with a person at the Mac (permissions, microphone, real apps).

| Milestone | Built | Verified here | Acceptance still needs you |
| --- | --- | --- | --- |
| M0 shell and permissions | ✅ | builds, signs with a stable local identity | Fresh install to "all green" in < 2 min |
| M1 audio and live transcript | ✅ | pipeline on synthetic speech (see below) | Real mic, AirPods unplug/replug, 30-min footprint |
| M2 context snapshot | ✅ | builds | Debug window updates within 1 s |
| M3 router and eval | ✅ | **98.5%** on the 45-case golden set (3 runs); p50 first tool call ~760 ms | — (600 ms goal waived: accuracy first) |
| M4 executors | ✅ | builds | `--action-script` run with real apps open |
| M5 turn handling | ✅ | unit tests | "ask cursor to… um… add tests" never fires early; 10 commands in one session |
| M6 safety | ✅ | 33 unit tests incl. every safety-table row and the injection case | — |
| M7 logging | ✅ | unit test: log → criteria table | Real two-week log |

## Log

- **Toolchain.** Only the Command Line Tools were installed, and half-updated (SwiftPM
  crashed on a dyld symbol mismatch). Deepam reinstalled them. Two further CLT-only gaps were
  worked around: SwiftUI macro plugins (KeyboardShortcuts vendored with a small patch) and
  `swift test` running nothing (`scripts/test.sh`). See DECISIONS 1–4.
- **Core library** (router prompt, tool schemas, SSE client, safety policy, transcript
  buffer, logging, eval grader) with 33 unit tests passing.
- **App**: menu bar, Settings (API key → Keychain, hotkey recorder, timings), Permissions
  onboarding, Fn event tap + ⌃⌥Space fallback, HUD (non-activating panel), speech engine,
  context snapshot, executors, session state machine, JSONL log.
- **`./build.sh`** produces a hardened-runtime signed `dist/VoiceCommand.app` (ad-hoc until a
  signing identity exists; see README › Signing).
- **Speech pipeline verified on synthetic speech** (`say` clips through the real VAD →
  streaming → TDT path via `VoiceCommand --transcribe-file`): "Switch to cursor", "Ask Claude
  Code why the build is failing", "Run npm test dash dash watch", "Undo that.", "Send it." all
  transcribed exactly; TDT re-transcription 44–158 ms per segment. A 1.5 s thinking pause
  splits into segments ("Ask cursor to" / "Uh" / "Add tests for the parser"), as designed.
  Found and fixed: end-of-speech took ~0.75 s to confirm; now ~0.5 s (DECISIONS 10).
  Known noise: CoreML prints one "E5RT … zero shape error" line per run; no transcript is
  affected.
- **Router eval with your key.** First run 97.8%, p50 964 ms: the model wrote reasoning text
  before tool calls. Forcing a tool call (`tool_choice: any`) plus four prompt rules took it
  to **98.5% (133/135 over 3 runs), p50 ~760 ms, p90 ~900 ms**, every reply a tool call,
  prompt cache hit on every call (4.4k cached tokens). The model's own floor here is ~665 ms,
  so the 600 ms goal is waived per Deepam (accuracy first). DECISIONS 37–40.

- **Stable signing.** Created the "VoiceCommand Local Signing" identity (scripts/make-signing-identity.sh,
  at Deepam's request). `dist/VoiceCommand.app` is now signed with it (hardened runtime), designated
  requirement = bundle ID + certificate, so permission grants survive rebuilds.

## Phase 1 of PLAN.md (3 Nov, after the first two real sessions)

Built; unit tests pass (36); not yet tried on the Mac or run through router-eval.
- **Tab switching fixed.** Chrome's tab and window IDs are text; `switchTab` compared them to a
  number, never matched, and activated the window's last tab (8 of 8 switches failed in the log).
  `closeTab` had the same bug. Both now compare as text and log the real AppleScript error.
- **Hold Fn to dictate.** Local only (no API key, no router): everything said while Fn is held
  is typed into the focused field on release, with fillers dropped and mid-sentence pauses
  mended (`Dictation`, Settings toggle). Password fields are refused; when no editable field
  is detected the text is also left on the clipboard. A tap still starts a command session.
- **Words are never dropped on a router error.** They stay in the buffer and the HUD says so;
  "type it" types them. Failed routes log events seen, stop reason and any reply text.
  Unconsumed speech now lasts 120 s (was 30), utterances over 20 words wait 0.9 s longer
  before routing, more dangling words ("like", "the", "to"…) wait, and the router has 1024
  output tokens (was 400) and 20 s once a tool call has started streaming (was 3 s total).
- **Echo cancellation** (Settings › Microphone, on by default): Apple voice processing on the
  input so a video playing on the Mac isn't transcribed. Falls back to the plain mic if the
  device refuses it.
- **Router prompt:** open/go to a site that's already open switches to it in any window; X and
  Twitter are x.com; "the other Chrome window"; "draft a prompt…" types into the focused field.
  "Xcode" removed from speech boosting (it turned "X.com" into "Xcode"). 6 golden cases from
  the 3 Nov log added (51 total).

## Phase 2 of PLAN.md, plus features from the 4 Nov sessions (4 Nov)

Built; 48 unit tests pass; router-eval **100% (124/124 over 2 runs)** on 62 cases, 17 of
them new from the 3–4 Nov logs; p50 first tool call 731 ms. Not yet tried on the Mac.
- **Reliability:** empty replies logged and retried on a fresh connection; echo cancellation
  only while the Mac plays audio; typing pastes and copies when no text box is visible;
  terminal and tab lists use a longer timeout and fall back to the last good list; a
  terminal *window* ID resolves to the session in it; a terminal opened by voice is the
  default for commands; misheard shell commands fixed in speech (aliases) and in the router;
  `cmd+minus`, `-`, `=`, `plus` parse; scrolling goes left and right.
- **New:** `menu_command`, `click_element`, `focus_text_box`, `describe_screen` (any app or
  web page, no per-app code); `rewrite_draft` ("improve the English"); `start_dictation`
  (dictation by voice until "send it" / "done" / 8 s of silence); type-then-confirm for
  terminal commands; the front terminal's last lines as context; tabs ranked by what was said
  so tabs past #40 are reachable; a personal dictionary in Settings plus names from the screen.
- **Latency logging:** each command records `segmentLagMs` and `transcribeMs`; each session
  records `echoCancel`.

## After the 4 Nov midday session (73 commands)

Built; 51 unit tests; router-eval **100% (138/138 over 2 runs)** on 69 cases (7 new from
this session). Checked against the real apps with `--dump-ax`: Claude's text box found in
45 ms ("Write your prompt to Claude"), Slack's in 55 ms; their sidebars read in < 0.1 s.
- **"Didn't catch that (events: 0)" was never the API.** You kept talking, newer speech
  cancelled the request, and a cancelled stream ends silently; it was reported as an empty
  reply. Now it's logged as cancelled with no error shown.
- **Latency** was 2.6 s median: 0.77 s speech end → transcript, 0.52 s reading the screen,
  0.86 s model, 0.36 s action. The screen is now read while you speak (prefetch at speech
  start) and reused when routing. Echo cancellation off when nothing plays confirmed the
  earlier 0.9 s: the wait before routing is back to 0.75 s.
- **Context:** the front window's clickable names (inside the page, for a browser) go to the
  router with every command, so "open Products" in Claude clicks Projects instead of searching
  Google. The router compares names by sound and spelling with what's on screen first.
- **Sound-alike matching** (`NameMatch.phonetic`): "Blue IO" → Blooio, "clawed" → Claude, for
  clicks and tab ranking. Closing a tab matched only by sound asks first.
- **Speech:** "Claude Code" removed from boosting (it turned "Claude" into "Claude Code");
  spelled-letter aliases removed ("p w d" produced "B Pwd O").
- **Text box:** Electron wraps whole windows in "editable" groups and the old walk stopped at
  the outermost one; it took minutes on Claude. Rewritten breadth-first with batched calls.
- **Terminal:** placeholder commands (`<UNKNOWN>`) refused, the router asks for the missing
  name; "no" clears the typed line with ⌃U (only when that terminal is in front); "remove the
  commands you typed" → ⌃U instead of typing the request.
- **Debug:** `open -n dist/VoiceCommand.app --args --dump-ax "<App>" <file> [--fast-only]`.

## After the 4 Nov afternoon session (61 commands)

Median speech end → done **2.07 s** (was 2.6 s); reading the screen now costs 0 ms because
it's prefetched while speaking. Built since; 51 unit tests; router-eval **100% (150/150)**
on 75 cases.
- **Follow-ups know the last command.** Session history now includes failed and refused
  commands, marks the most recent, and a question the app asked ("Do you want me to open
  Projects?") is passed on, so "yeah", "not this one", "the other one", "that was wrong" and
  "do it again" act on it. 6 new golden cases.
- **"What can you do here?"** shows a larger card under the bar for ~12 s (speaking hides it):
  on-screen names grouped by area (sidebar, top bar, main, near the text box), menus, and
  examples. Controls sent to the router are spread across those areas (80 max) so the ones
  by the text box aren't crowded out.
- **Slack:** typing finds the message box when focus isn't in one (was a blind paste); list
  rows are clickable (DMs and channels: "Deepam Goyal (you, active)"); 1-px virtualised items
  no longer count as visible.
- **Clicks** look deeper (1.5 s budget) and look again after 0.5 s if a page is still loading.
- **Continuous scrolling:** "keep scrolling up" scrolls until anything is said (a misheard
  "stop" still stops it), 30 s at most.
- **Timeouts** retry once on a fresh connection before giving up.
- `--dump-ax` now reads with batched calls (Slack and Chrome dump in seconds).

