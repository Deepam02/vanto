# Decisions

Where the PRD was ambiguous or the environment forced a choice, I took the simplest safe
option and noted it here. "Final review" refers to the PRD section that overrides the rest.

## Build and toolchain

1. **SwiftPM package instead of an Xcode project.** The machine has only the Command Line
   Tools (no Xcode, no `xcodebuild`), so an `.xcodeproj` couldn't be built. `Package.swift`
   opens in Xcode if you install it later. `build.sh` assembles `dist/VoiceCommand.app` by hand
   (Info.plist, entitlements, resource bundle) and signs it with the hardened runtime.
2. **Swift 6 toolchain, Swift 5 language mode** for every target (Final review 18).
3. **KeyboardShortcuts is vendored** (`Vendor/KeyboardShortcuts`, 3.1.0, MIT) with small
   patches listed in `Vendor/KeyboardShortcuts/PATCHES.md`: the SwiftUI `#Preview`/`@Entry`
   macros need plugins that ship only with Xcode, and SwiftPM's `Bundle.module` can't find
   resources inside a hand-assembled `.app`. It is still the only hotkey dependency; no
   behaviour change.
4. **Tests use Swift Testing through `scripts/test.sh`.** With only the CLT, `swift test`
   builds the test bundle but runs nothing (and XCTest isn't installed). `scripts/test.sh`
   loads the bundle into a 15-line runner that calls Swift Testing's own entry point. With
   Xcode installed it just calls `swift test`.
5. **Signing.** No Apple Development identity exists on this Mac. `build.sh` uses, in order:
   `$SIGN_IDENTITY`, any Apple Development / Developer ID identity, a self-signed
   "VoiceCommand Local Signing" identity (created by `scripts/make-signing-identity.sh`),
   else ad-hoc. Ad-hoc works but macOS forgets the Accessibility grant on every rebuild; I
   did not create the self-signed identity for you because it writes to your login keychain.
6. **Bundle ID** `com.deepamgoyal.VoiceCommand`, fixed so permission grants stick.
7. **No `.bundle` at the `.app` root.** FluidAudio's only resource bundle is for TTS, which
   the app never calls, so it isn't shipped.

## Speech

8. **Models:** Parakeet TDT **v2** (English-only, per "English only" in Open questions) for the
   final transcript; the streaming Parakeet EOU 120M model at 320 ms chunks for live HUD text;
   Silero VAD (FluidAudio's default VAD) for endpointing. FSMN-VAD (mentioned in research) was
   not chosen: Silero is the documented default and the PRD's build spec names it.
9. **Custom vocabulary** needs FluidAudio's separate CTC 110M encoder with TDT 0.6B models
   (~100 MB extra). Terms: Cursor, Claude, Claude Code, Ghostty, iTerm, npm, GitHub, ChatGPT,
   Codex, Slack, pnpm, Xcode, localhost, Vercel, Linear, Chrome, PR, README, plus running app
   names at session start. If the CTC model fails to load, transcription continues without
   boosting.
10. **Endpointing:** VAD `minSilenceDuration` 0.1 s on 256 ms chunks (end confirmed ~0.5 s after you stop; 0.3 s took ~0.75 s), then the fixed commit
    delay (default 450 ms, Settings 250–1500 ms) measured from the VAD's end-of-speech sample.
    Speculation and the amend window are cut (Final review 9).
11. **Segments:** each VAD speech run is one transcript segment, re-transcribed once when it
    ends. Segments over 14 s are split by the VAD (`maxSpeechDuration`). Clips under 1 s are
    zero-padded for TDT.
12. **Mic device change ends the session** (Final review 8) rather than reconnecting; the
    change is debounced 500 ms on the audio queue so it can't crash mid-rebuild.

## Turn handling

13. **"Thinking pauses" local rule.** With the setting on (default), an utterance ending in
    um/uh/er/erm/hmm/and/so/then/or/but/because is not sent to the router at all; it just
    waits. Saves a round trip and can never fire early.
14. **Mute is spoken and local**: "pause listening" mutes without a router call; while muted,
    speech is transcribed only to hear "resume" / "resume listening" / "start listening".
    Esc is not used (Final review 5). The menu bar has Pause/Resume too.
15. **"hold on" / "wait" / "let me think"** suspend the idle timeout until the next speech.
16. **Router errors drop the utterance** (cursor moves past it) so a failed call can never be
    re-sent and run later. Never auto-retry an action (Final review 16).
17. **No tool call** → one retry, then "Didn't catch that" (build spec).
18. **3 s router deadline** is enforced with a watchdog; if no tool call has arrived the reply
    is abandoned and nothing runs.

## Router and tools

19. **Tool list** = build-spec JSON + Final review 1 (`scroll`, `newline`, `clear_typed`,
    `ignore` added; `arrange_window`, `minimize_window`, `close_window` removed). I also
    **removed the `browser` parameter** from `browser_open_url` / `browser_new_tab`: Safari is
    cut, so it could only mislead.
20. **Golden-set row "put chrome on the left and the terminal on the right"** expected two
    `arrange_window` calls, but that tool is removed. The row now expects `say` (one short
    "can't do that yet").
21. **Golden set grown to 44 cases** from the PRD's own tables (UX, thinking pauses, safety,
    drafting, pending). The 15 seed rows are all still there. `router-eval` also replays each
    reply through the local safety policy where the case names an expected outcome.
22. **`terminal_run` targets a plain shell**, not the session running Claude Code (typing a
    command into Claude's prompt would send it to Claude). Added to the prompt and to the
    executor's default-session choice.
23. **API version** `anthropic-version: 2026-10-21`; request has no sampling parameters
    (they 400 on that version). `thinking: disabled` + `effort: low` is valid on Haiku 5.5.
24. **Cache warm-up**: a `max_tokens: 0` request with the real tools/system at session start
    opens the HTTP/2 connection and writes the prompt cache (the documented pre-warm).

## Safety

25. **Two tiers** exactly as Final review 7. Additionally:
    - `confirm_pending` runs only if the latest utterance contains an approval word
      (yes, yeah, run it, do it, go ahead, confirm, …), so a misrouted reply can't approve.
    - `press_keys` "enter" while a draft is open counts as a send: it needs the word
      "enter"/"return" in the latest utterance, so it can't bypass the send-word gate.
    - `sudo` is always refused (PRD: "never sudo in the MVP").
    - "Dictated verbatim" is checked locally against the (symbol-mapped) transcript; the
      router's `source: verbatim` label alone is not trusted.
26. **Typed text is always the transcript's own words.** If the router's payload matches the
    transcript after normalising case/spacing/punctuation, the transcript span is typed
    (with Parakeet's punctuation). A paraphrase is replaced by the best-aligned transcript
    span; below 60% word overlap nothing is typed.
27. **A new command cancels a pending action** (state machine), except draft actions
    (type/newline/clear/submit), which can coexist with it.
28. **Screen Recording is shown in the permissions screen as "Not needed"** (M0 lists it; the
    Final review removed the need). "All green" doesn't require it.
29. **Privacy denylist** (password managers, Keychain Access) lives in the editable
    `AppHints.json`: those apps' window titles, focused-field labels and values are never
    put in the snapshot. Banking apps aren't listed by default (no reliable bundle IDs);
    add yours to the file.
30. **Focused-field value** is sent as at most its last 60 characters, never for password
    fields or denylisted apps.

## Context

31. **Chrome only** (Google Chrome). Brave/Edge/Arc aren't queried. Tab IDs
    `chrome:<windowId>:<tabId>`.
32. **Event-driven snapshot.** During a session the snapshot refreshes on every app switch and
    right before each router call (PRD efficiency rule 5: no polling). Only the debug window
    polls every 1 s, which is what M2's "updates within 1 s of switching tabs" needs, since a
    tab switch inside Chrome fires no notification. Nothing runs when idle.
33. **Claude/Codex detection**: one `ps -A -o tty=,comm=` per snapshot for Terminal/iTerm2
    sessions; Ghostty has no tty in its dictionary, so its sessions use the title
    (Claude Code titles contain "claude" or start with ✳).

## UX

34. **First launch downloads models in the background** with a progress bar in the HUD, and
    shows the permissions window until everything is green.
35. **Models unload 10 minutes after the last session** and reload (1–3 s, "Warming up…") on
    the next hotkey press.
36. **M4 harness**: `--action-script` runs scripted tool calls through the real policy and
    executor without the router (`Tools/action-script/golden-actions.json`).
