# Never lose dictation

Feature spec, 4 Nov 2026. Branch `feature/never-lose-dictation`. Companion to
`docs/specs/memory-and-learning.md` (separate PR); the two meet at one point, §9.

## 1. The problem, from the logs

"Sometimes I just want to dictate things without saying 'write this down'. It should still
work." (Deepam, 4 Nov). Today it doesn't, and when it fails the words are gone.

What happened in the 3–4 Nov sessions (325 routed utterances, `commands.jsonl`):

| # | Said | What Vanto did |
|---|---|---|
| 321–323 | "At the end of the day, I think we have to build a product which is for any person…" (60 words, no instruction) | Router chose `ignore`. Every word thrown away. |
| 314–315 | "Enter into dictation [Claude] Code" | Asked "which app?" twice instead of starting. |
| 27, 71–75 | Long prompts with pauses | Router errors and timeouts; the words were consumed or timed out. |
| 75 | A prompt for Claude desktop | `type_text` failed ("No text field is focused") and the words were consumed. |
| 151 | A complaint *to Vanto* ("Don't clear it by a clear…") | Typed into the terminal as text: the opposite mistake. |
| 296–298 | Netflix dialogue ("Welcome to Arrakis…") | Correctly ignored. Typing everything is not the answer either. |

Today there are nine ways words leave Vanto without being acted on or typed:

1. The router returns `ignore` → the buffer is consumed (`SessionController.route`).
2. Unconsumed speech older than 120 s is dropped (`TranscriptBuffer.dropStale`), including
   words "kept" after a router error and phrases left waiting on a thinking pause.
3. A failed action consumes its words (`anyFailed` → `consume`), e.g. "No text field is focused".
4. Ending a session discards the unconsumed command buffer.
5. "never mind" / "cancel that" as a whole segment erases an entire voice dictation, with no
   way back.
6. A mute phrase consumes everything said with it (`consumeAll`).
7. Speech that stops a continuous scroll is dropped if it has ≤ 4 words (intended for
   "stop", but it also eats a short real command).
8. Clarifying questions ("which app?") leave the content stranded in the buffer, to be
   dropped by (2).
9. Hold-Fn text that pastes into nothing is copied to the clipboard, overwriting it, and the
   person isn't told clearly.

The root cause isn't one bug. **Dictation is decided by the router as a side effect**, and
**"not acted on" is allowed to mean "deleted"**.

## 2. Goals and non-goals

**Goals**
- Plain speech into a text box is typed: no trigger words, no mode to enter.
- Commands still work exactly as now, with no extra latency for them.
- No spoken words are ever silently lost. Every utterance ends somewhere the person can see
  and get back.
- A wrong guess costs one short phrase to fix, in either direction.
- One dictation engine behind all three entry points (hold Fn, "write a message…", just
  talking).

**Non-goals (this PR)**
- Learning the person's words and names (the memory PR).
- Editing typed text by voice beyond what exists (`rewrite_draft`, "scratch that").
- Wake-word or always-on listening. Sessions stay push-to-start.

## 3. The contract: where every word ends up

Every finalised speech segment ends in exactly one of four places:

| Disposition | Meaning | Visible as |
|---|---|---|
| **Acted** | Part of a command that ran (or is pending a yes) | HUD result, history |
| **Typed** | Pasted into a text field as dictation | The text itself; HUD "Typed into X" |
| **Kept** | Not acted on and not typed: noise, unclear, nowhere to type, an error, a timeout | HUD note when it matters; **Kept** list in the menu bar |
| **Discarded by you** | You said "scratch that" or "cancel dictation" | HUD "Removed"; still in Kept for 10 minutes |

Invariants, enforced in code and tested:

- **I1.** No code path removes a segment from the buffer without one of these dispositions.
  `TranscriptBuffer` loses `dropStale` and `consumeAll`. Leaving the buffer always means
  `dispose(ids, as: .acted | .typed | .kept(reason) | .discarded)`, and `.kept` and
  `.discarded` write to the Kept store.
- **I2.** Typed text is the person's words: fillers removed, punctuation tidied, nothing
  paraphrased (as today).
- **I3.** Dictation never sends by itself. Only an end phrase *at the end* ("…send it")
  sends, as today.
- **I4.** If a command is typed by mistake, "that was a command" removes exactly what was
  typed and routes those words as a command.
- **I5.** If dictation is acted on by mistake, the action is undoable as today, and the words
  are in Kept, so "type that instead" types them.

The Kept store: the last 50 items or 24 hours, on disk at
`~/Library/Application Support/Vanto/kept.jsonl` (local only), cleared from Settings.
Background noise is kept silently; everything else gets a HUD line.

## 4. What it feels like

| Situation | You say | Vanto |
|---|---|---|
| Claude Code focused in the terminal | "So basically I'm running a session and I think we need to improve…" (pauses, ums) | Types it as you go, mending mid-sentence pauses. HUD: **Dictating into Claude Code — "send it" to send**. |
| …then | "send it" | Presses Enter. |
| Slack message box focused | "Hey Priya, the deck is ready, I'll walk you through it tomorrow" | Types it. "Send it" is not at the end, so nothing is sent. |
| Slack focused | "switch to Chrome" | Switches. Short, imperative, names an app: a command. |
| No text box focused (Finder in front) | A paragraph | **Kept**: "Kept your words — click a text box and say 'type it', or 'copy it'." |
| A video playing, nothing said to Vanto | Dialogue from the video | Kept silently (nothing typed, no HUD). |
| Dictating into Gmail | "…and that's why we should close the deal by Friday" | Typed. "Close" is mid-dictation, inside a sentence. |
| A command got typed | "that was a command" | Removes what was just typed and runs it as a command. |
| A thought got acted on | "no, type that" | Undoes the action if it can, then types the words. |
| Anything | "what did you keep?" | Reads the last kept items in the HUD; "type the last one", "copy it". |

Entry points, all into the same engine:
- **Just talk** with a text box focused (new, default on).
- **Hold Fn**: dictation only, never a command (as today).
- **"Write…", "type…", "take a note…", "dictate into Claude Code…"**: starts dictation,
  optionally targeting an app (as today, plus "enter dictation [into X]" handled locally).

## 5. Design

### 5.1 Where dictation is decided

```
segment ─► Disposition tracker ─► Intent decision ──┬─► Dictation run ─► typed / kept
              (§3, I1)              (§5.3)           ├─► Router ─► acted / pending / kept
                                                     └─► Kept (noise, background audio)
```

The intent decision moves out of the router and in front of it. The router still breaks ties
(§5.4) but can no longer delete words.

### 5.2 Context the decision uses

A small `IntentContext`, built from the snapshot that is already prefetched when speech
starts:

| Signal | Source | Effect |
|---|---|---|
| **Focus kind**: `textField(app)`, `assistantPrompt(app)` (Claude Code / Codex session, Claude, ChatGPT, Cursor chat), `shell(session)`, `secure`, `none` | `snapshot.focused`, terminal `running` | Where dictation could land. Plain shell and secure fields never receive implicit dictation. |
| **Dictation run active** (and its target) | Dictation engine | Sticky: continuation is dictation unless clearly a command. |
| **Draft open** | Executor | Continuation goes to the same target. |
| **Media playing** | `AudioCapture.outputIsPlaying()` | Raises the bar for typing; background speech is kept, not typed. |
| **Last command age** | Session history | Right after a command, short follow-ups are more likely commands. |
| **Hold Fn** | Hotkey | Forces dictation. |

### 5.3 The decision, in order (cheap and certain first)

1. **Forced.** Hold Fn → dictation. "Vanto, …" → command (new explicit prefix; also
   recognised mid-dictation as an escape).
2. **Dictation run active.**
   - An end phrase at the end ("send it", "done", "stop dictating") ends it (existing
     `Dictation.endCommand`).
   - "That was a command", "scratch that", "cancel dictation" are recovery commands (§5.6).
   - Otherwise the segment continues the dictation, unless the local command check (step 4)
     is certain *and* the segment is short.
3. **Explicit start.** "type / write / dictate / take a note / note that / enter dictation
   [into X] …" → start a run, with the remainder as its first words. This is handled locally,
   with no router call, so "enter dictation into Claude Code" just works.
4. **Local certainty, both ways.** Only decisions the evidence supports:
   - **Certain command:** ≤ 12 words, *and* it starts with a command cue ("can you", "go
     to", "open", "switch", "click", "scroll", "zoom", "close", "run", "search", "what can
     I…", …) *or* contains "can you / could you" anywhere, *and* it doesn't read like a
     message to a person. → router.
   - **Certain dictation:** a text field or assistant prompt is focused, ≥ 14 words, no
     command cue at the start, no "can you / could you" anywhere, and first-person or
     addressed-to-someone prose. → dictation run.
   - **Certain noise:** media playing, no command cue, and nothing said to Vanto in the last
     ~10 s → kept silently.

   The thresholds come from the logs (§7). On the 325 utterances, a looser version of the
   dictation rule caught both long implicit dictations, but also took 3 commands that
   contain "can you" mid-sentence ("I think the terminal session is open, right? … Can you
   Google Chrome"). Hence "no 'can you' anywhere" on the dictation side.
5. **Everything else → router**, which now has two new choices (§5.4). Short follow-ups such
   as "That's how we will grow it into a big…" land here, with the run's context ("dictation
   just happened into Claude Code") to tip the call.

Steps 1–4 are a pure function, `IntentGate.decide(utterance, context) → Decision`, in
VoiceCommandCore, unit-tested and replayable.

### 5.4 Router changes

- **New tool `dictate(target?)`** — "the person is dictating text, not giving a command".
  **No payload.** Vanto types the transcript itself, so long dictation can't hit
  `max_tokens`, be paraphrased, or slow the reply. `target` is optional: focused field, a
  named app, or the draft.
- **`ignore` becomes `keep(reason)`**, with reason `noise | not_for_me | unclear`. Same
  behaviour for the router (it moves on), but the words go to Kept. The bare-"stop" rule
  added on 4 Nov becomes `keep(noise)`.
- **Clarifying questions keep the content.** When the router asks "which app?", the words
  stay attached to the question. A one-word answer ("Claude Code") completes the original
  request instead of becoming a new one. Today's `you_just_asked` covers yes/no; this
  extends it to a target.
- **Prompt rules:**
  - with a text field or assistant prompt focused, prose that reads like a message, prompt
    or note is `dictate`, even if it says "you" (prompts to Claude Code are addressed to
    Claude, not to Vanto);
  - Vanto is addressed only when the words ask for something Vanto can do on this Mac.
- **Golden set:** every `ignore` case becomes `keep`; add about 20 cases from the logs and
  from persona prose (email, Slack, notes, prompts) with and without a field focused.

### 5.5 One dictation engine

`DictationController` (new, app target) replaces the three current paths: `dictationOnly` +
`dictated`, `voiceDictation`, and router-typed payloads. It owns:

- **A run:** target (pinned at start: app, element or terminal session), the segments
  received, the text typed so far, how it started (hold Fn / spoken / implicit) and how it
  ends.
- **Typing as you go** (implicit and spoken runs). Each finished segment is cleaned
  (`Dictation.clean`) and typed into the pinned target.
  - When the previous segment ended mid-sentence ("we need to." + "improve the screens"),
    the engine backspaces the stray period and lowercases the next word. It typed that
    period itself, so it knows it is there.
  - Hold-Fn keeps its current behaviour: everything is typed once on release.
- **Target changes mid-run.** If focus moves to another app, the run pauses. The next segment
  starts a new run in the new place only if a field is focused there. Otherwise it goes to
  Kept with "you moved away from Claude Code — say 'type it' to put it here".
- **Ending:** end phrase, an explicit command (typed text stays, unsent), the session ending
  (text stays, unsent), or 8 s of silence for spoken runs and 4 s for implicit ones.
  Implicit runs end quietly: the text is already typed.
- **Failure:** if typing fails (field gone, not editable), the segment goes to Kept with the
  reason, never consumed. This closes loss path (3).

### 5.6 Recovery commands (handled locally, no router call)

- **"that was a command" / "do that instead":** removes what the last run typed (backspaces,
  as `clear_typed` does) and routes those words as a command.
- **"no, type that" / "type that instead":** after a command, undoes it if it can, then
  types the words.
- **"scratch that":** removes the last typed chunk. The words go to Kept as discarded.
- **"type it" / "paste it" / "copy it" / "what did you keep?":** acts on the newest Kept
  item (or "the last one", "the one about the deck").

### 5.7 Background audio
- With media playing, the local noise rule (§5.3 step 4) keeps speech silently unless it
  carries a command cue or follows something said to Vanto.
- Echo cancellation stays as is (on only while audio plays).
- Kept is the safety net. If the movie line was actually you, "type it" recovers it.

### 5.8 Logging
Every `CommandRecord` gains:
- `intent`: the decision step and reason, e.g. "local: certain dictation (assistant prompt,
  31 words)";
- `focusKind`;
- `disposition` per segment;
- `mediaPlaying`.

`log-report` adds:
- **words lost: must be 0**, computed as segments without a disposition;
- **typed-then-"that was a command"** rate (false dictation);
- **"type that instead"** rate (false command);
- **Kept items later recovered**.

## 6. Code changes

| Where | Change |
|---|---|
| `VoiceCommandCore/Session/TranscriptBuffer.swift` | Replace `consume`, `consumeAll` and `dropStale` with `dispose(_:as:)`; stale segments are disposed as `.kept(.stale)` |
| `VoiceCommandCore/Session/KeptWords.swift` (new) | Model, ring buffer, JSONL persistence, query ("last", by words) |
| `VoiceCommandCore/Intent/IntentGate.swift` (new) | `IntentContext`, `Decision`, the ordered rules of §5.3; explicit-start parsing ("enter dictation into X") |
| `VoiceCommandCore/Session/Dictation.swift` | Mid-sentence mending as an incremental step (what to backspace), recovery-phrase detection, "never mind" requires the run to be < 3 s old or goes to Kept |
| `VoiceCommandCore/Router/*` | `dictate`, `keep` tools; `ignore` removed; prompt rules and examples; clarifying-question carry-over |
| `VoiceCommand/Session/DictationController.swift` (new) | The single engine (§5.5) |
| `VoiceCommand/Session/SessionController.swift` | Every segment → gate → dictation / router / kept; the three old dictation paths removed; no consume without a disposition |
| `VoiceCommand/UI/HUDPanel.swift` | "Dictating into X" badge with target; Kept notes |
| Menu bar | "Kept" submenu: last 10, click to copy |
| `Logging/*`, `log-report` | Fields and metrics of §5.8 |
| Tests | `IntentGateTests`, `KeptWordsTests`, disposition invariant test, extended `DictationTests` |
| `Tools/intent-eval/` (new) | Labelled utterances from the logs plus persona prose; `swift run intent-eval` reports per-class precision and recall for the local gate |

## 7. How we'll know it works

1. **Invariant test.** Fuzz the session with random sequences of segments, router results
   (including errors and timeouts), focus changes and session ends. Assert that every
   segment gets exactly one disposition.
2. **Intent eval on real speech.** The 325 logged utterances, hand-labelled (command /
   dictation / background / mixed), plus ~60 persona utterances (emails, Slack replies,
   notes, prompts, commands).
   - The local gate must have **0 commands classified as certain dictation** and 0
     dictations classified as certain command.
   - What it isn't sure about goes to the router.
   - The router eval adds the `dictate` and `keep` cases; target ≥ 95% on them.
3. **Replay of the 3–4 Nov failures.** 321–323 is typed into Claude Code; 314–315 starts
   dictation; 75 lands in Kept with "type it" working; 296–298 is kept silently; 151 goes to
   the router, not typed.
4. **Live checklist (Deepam):**
   - dictate three prompts into Claude Code with long pauses;
   - a Slack reply;
   - a paragraph with Finder in front (→ Kept, "type it" after clicking a box);
   - a video playing for 2 minutes (nothing typed);
   - "that was a command" once.

Acceptance: zero lost words over a day of use (`log-report`), and no more than 1
false dictation per 50 commands.

## 8. Rollout
- **Settings → "Type what I say when I'm not giving a command"**, on by default; off
  restores the router-only behaviour (but still keeps instead of dropping).
- **First time it types implicitly,** the HUD adds one line: "I typed that because a text
  box was focused — say 'that was a command' if it wasn't." It is shown three times, then
  never again. This is how people learn the feature exists and how to correct it.

## 9. Interaction with memory and learning
Memory normalises *names* in the transcript before this gate (so "Blue IO" is already
"Blooio"), and supplies command-word aliases only on the command side. A typed dictation
never has command-word rewrites applied ("store" stays "store"). Corrections from this
feature ("that was a command", "type that instead") are learning signals for the memory PR:
they teach which of your phrasings are commands.

## 10. Risks and open questions
- **Dictating prose into a code editor** (Cursor's editor, not its chat) types prose into
  code. That is what dictation tools do, and undo fixes it. Revisit if the logs show it.
- **Very short dictation** ("yes, works for me") into Slack is ambiguous with a reply to
  Vanto's question. Rule: if Vanto just asked something, a short answer answers Vanto.
  Otherwise, with a field focused, it's dictation only if the router says so.
- **Kept is local speech history.** It is kept for 24 h, cleared from Settings, never sent
  anywhere. If that's too much, 1 hour is the fallback.
- **Open:** should implicit runs type per segment (live, current proposal) or on a pause
  (one clean paste, like hold Fn)? Live typing shows progress on long prompts; on-pause
  typing is cleaner. I propose live typing and will check it on day one.
