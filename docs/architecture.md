# Vanto architecture: one voice layer for every app and every person

Proposal, 4 Nov 2026. Supersedes the order of work in `PLAN.md`; builds on
`docs/generic-control.md` (menus → accessibility → screen agent), which stays the action ladder.
Status: **for Deepam's review — no code changes until agreed.**

## 1. Why change course

Vanto today is a developer tool grown one failure at a time:

- **A closed list of ~30 tools**, many hand-wired to one app (Chrome tabs over AppleScript,
  three terminal dialects, a five-app chat-box table). Every new app or task is new code;
  anything outside the list is "I can't do that yet".
- **The router decides everything, including whether you were talking to it.** On 4 Nov a
  dictated paragraph ("At the end of the day, I think we have to build a product…") was
  classified `ignore` and thrown away. So were "Closure this window" (close) and "Store the
  session" (stop): mishearings with no matching tool.
- **One shot, no loop.** Words → tool calls → done. Nothing re-reads the screen and decides
  the next step, so "open the PR and approve it" can't work.
- **Safety keyed to tool names** (`submit`, `terminal_run`, a word list on buttons). ⌘↩ in
  Slack or Gmail, or a button called "Post", slips past it.

The target is everyone with a laptop — marketers, students, designers, founders, PMs,
salespeople, writers, people with RSI — not developers. That raises the bar on three things
developers tolerate: losing words, learning commands, and surprises.

## 2. What the research says (short)

Full notes from three research passes are summarised here; sources in §12.

1. **Dictation is where voice clearly wins.** Speech is ~150 WPM against ~52 WPM typed on a
   laptop, about 3× for raw text (Ruan et al. 2017; Dhakal et al. 2018). The gain disappears
   when correcting is expensive: 1999 studies found voice corrections cascading and experts
   giving up on them (Karat 1999; Halverson 1999). LLM clean-up is what makes dictation work
   now, and it is why Wispr Flow is the fastest-growing product in the space.
2. **Voice loses at pointing, fine selection and short shortcuts.** It wins at *named*
   targets ("open Linear", "reply to Sarah") and at things buried in menus or several app
   switches away. Voice should name things, not point at them.
3. **Nobody throws away speech.** Apple Voice Control, Dragon and Windows Voice Access type
   anything that isn't a command; a wrong guess costs one "scratch that". Aqua treats
   "send it" as a command only when it is the last thing said, so "tell them I'll send it
   tomorrow" stays text. Talon (command-first) is loved by experts and hostile to everyone
   else.
4. **Every product still makes you pick a mode or a key** for commands (Wispr's Command Mode
   is off by default and Pro-only). No Mac product combines dictation, voice editing and
   dependable everyday control: Dragon left Mac in 2018, Voice Control reads as an
   accessibility tool, and agent products are slow screenshot loops ("minutes for
   seconds-long tasks").
5. **General agents that work in any app all share one shape** (Microsoft UFO², Claude Code's
   computer use, Agent S): try the most precise channel first (API → accessibility → vision),
   verify after acting, batch actions with precondition checks, and keep a human in the loop
   for consequential steps. Screenshot loops cost seconds per step; they are a fallback.
6. **Only about a third of Mac apps have full accessibility support** (Screen2AX, 2025).
   "Any app" needs menus, accessibility, keyboard shortcuts *and* vision.
7. **Trust is per action, not per product.** People grant autonomy for low-stakes steps and
   want previews and confirmation for anything irreversible or visible to others. Screen
   capture is a privacy flashpoint (Wispr's February 2026 backlash).
8. **Social use is the main barrier for a general audience** (people rarely talk to computers
   in public or at work). Push-to-talk, whisper tolerance and quiet feedback matter.

## 3. Principles

1. **Never lose words.** If Vanto isn't sure it was a command, it is text. Text goes into the
   focused field; if there's no field, it waits in the HUD and on the clipboard.
2. **Dictation is the default.** Talk and it types. No "write this down", no mode to enter.
3. **Commands are recognised, not required.** Natural phrasing, no syntax to learn, and
   "what can I say here?" always answers with real names from the screen.
4. **Correction is cheap.** "Scratch that", "make it shorter", or just fix it with the
   keyboard. Undo covers actions as well as text.
5. **One mechanism for every app.** App-specific code is only a fast path or a quirk table.
6. **Safety follows the effect.** Reading and navigating run; anything that sends, posts,
   deletes, pays or runs a risky command asks first, whatever produced it.
7. **Fast where it's simple, thorough where it's not.** Instant for "switch to Slack";
   seconds, with visible steps, for "set up the Q3 review doc".
8. **Private by default.** Speech stays on the Mac. The screen is read as text, the smallest
   amount needed; screenshots only for the slow path, shown when taken.
9. **Accuracy beats latency** (Deepam, 3 Nov). Never trade correctness for speed.
10. **Every behaviour is testable** against recorded sessions before it ships.

## 4. The interaction model

### One key, one session
- **Tap Fn** starts or ends a session; **hold Fn** dictates only (nothing is ever treated as
  a command while held). Sessions end on Fn, "that's all", or idle time, as today.
- Within a session you just talk. Each finished phrase is one of five things:

| You say | It is | What happens |
|---|---|---|
| Prose, no clear instruction ("Hi Sam, the deck is ready…") | **Dictation** | Typed into the focused field, cleaned (fillers, punctuation), your words kept |
| A clear instruction ("switch to Slack", "zoom out", "open the pricing tab") | **Command** | Done at once if reversible; HUD shows what happened |
| An edit of what you just said or selected ("make it more formal", "scratch that") | **Edit** | Only Vanto's own draft or the selected text changes; undo restores it |
| A question about the screen ("what can I do here?", "which tab has the invoice?") | **Question** | Answered in the HUD; can never act |
| A goal with steps ("find last week's invoice from Acme and forward it to Priya") | **Task** | Steps shown as they run; anything that sends asks first |

### Deciding dictation versus command
The router no longer has an `ignore` choice. The **intent gate** (§5, L1) decides:

1. **Explicit beats inferred.** Holding Fn, "type …", "dictate …" force dictation;
   "Vanto, …" or "command …" force a command.
2. **Shape.** Commands are short and imperative, start with a verb or a known name, and refer
   to something that exists (an app, a place, a menu item, a visible label). Dictation is
   long, first-person or addressed to someone else, and refers to nothing on screen.
3. **Position, Aqua-style.** "Send it", "enter it", "new line" count as commands only at the
   end of the phrase.
4. **Context.** With a text field focused and a draft in progress, ambiguous speech is
   dictation. With no field focused, ambiguous speech goes to the router as a possible
   command.
5. **When unsure, type it**, and show "Typed — say 'that was a command' to run it instead".
   The reverse mistake (running dictation) is the one we must not make.

Background talk with a session open is handled by the mute ("pause listening") and by the
fact that typed-by-mistake text is one "scratch that" away — the same trade every dictation
product makes.

### Feedback
The HUD always shows: the mode badge (Dictating / Command / Task / Question), what was
heard, what was done, and for anything consequential a one-line summary to approve
("Send 'Hi team…' to #growth in Slack? Say yes"). A history panel lists the last actions
with undo.

## 5. Architecture

```
 L0 Audio & turn-taking ─► L1 Intent gate ─► L3 Planner ──────────────► L4 Effect policy
                                  ▲          fast path │ router │ agent      │ run / confirm / refuse
 L2 Perception: Screen Graph ─────┴──────────────┤                            ▼
 L5 Memory: lexicon, places, habits, macros ─────┘               L6 Action drivers + verify
                                                                              ▼
                                                                 L7 Trace → replay and eval
```

| Layer | Job | Interface | From today's code |
|---|---|---|---|
| **L0 Audio & turn-taking** | Mic, VAD, on-device Parakeet, end of phrase, thinking pauses, mute | `Utterance{text, segments, endTime, confidence}` | **Keep** `SpeechEngine`, `AudioCapture`, `TranscriptBuffer` |
| **L1 Intent gate** | Decide dictation / command / edit / question / task (§4); dictation is handled here and never reaches the LLM | `Intent{kind, text, confidence, forced}` | **New.** Absorbs hold-Fn dictation, thinking pauses, mute, "send it" position rule |
| **L2 Perception** | One versioned **Screen Graph**: apps, windows, *places* (tabs, terminal sessions, Chrome profiles), focused element, selection, front app's menu commands with shortcuts, visible interactive elements with refs. Built lazily, cached per app; screenshot only on request | `ScreenGraph` (refs valid for one version) | **Evolve** `SnapshotBuilder`, `TerminalSessions`, `BrowserTabs`, the new menu/element code |
| **L3 Planner** | Turn an intent into a plan of verbs. **Fast path** (no LLM): exact or fuzzy match against places, menu items and labels, plus memory. **Router** (Haiku): one call, up to k actions. **Agent** (Sonnet/Opus): observe → act → verify loop with the same verbs plus the computer-use toolset | `Plan{[Action(verb, target, args, provenance)]}` | **Change** the router from ~30 tools to ~12 verbs; **add** fast path and agent loop |
| **L4 Effect policy** | Classify each *resolved* action by effect; decide run / confirm / refuse (§6) | `classify(Action, ScreenGraph, provenance) → EffectClass → Decision` | **Replace** tool-name tiers; **keep** `CommandRiskChecker`, approval-word check, secure-field refusal |
| **L5 Memory** | Personal lexicon (feeds speech vocabulary and aliases), named places ("the team channel", "work profile"), habits (last-used profile per site), user macros | Local SQLite, editable in Settings | **New**; `AppHints.json` becomes part of it |
| **L6 Action drivers** | Implement verbs through the most precise channel available: app scripting → menus → accessibility → keys → vision. Each returns `Verified` or `Unverified(reason)` by re-reading state | `Driver.perform(Action) → Result` | **Refactor** Chrome, terminal, window, paste and UI adapters into drivers; quirks become data |
| **L7 Trace** | One structured record per turn: audio ref, transcript, intent, graph hash, plan, effect, decision, result, timings | JSONL | **Extend** `CommandLog`; feeds replay tests |

### The verbs
Instead of a tool per app feature, the planner speaks about a dozen verbs that every driver
understands:

`go_to(place)` · `invoke(command | menu path | shortcut)` · `press(element)` ·
`focus(element)` · `insert_text(target, text)` · `set_text(element, text)` ·
`edit_draft(instruction)` · `scroll(direction, amount)` · `open_url(url)` ·
`run_shell(command)` · `answer(question)` · `escalate(goal)`

"Switch to the pricing tab", "go to the team channel" and "open my Notion" are all `go_to`.
"Zoom out", "new window", "duplicate slide" are `invoke` from the front app's menu. "Click
Conversations" is `press`. The model picks from what the Screen Graph shows, so a new app
works the day it is installed.

### Speed tiers
- **Fast path, no LLM (target < 300 ms after the phrase ends):** app and place switches,
  menu commands, "scratch that", "send it" — anything that matches exactly.
- **Router (≈ 1 s):** everything one call can plan.
- **Agent (seconds, steps shown, interruptible with Fn or Esc):** goals with several steps,
  or when the router escalates.

## 6. Safety by effect

Every resolved action gets one effect class, whatever verb or driver produced it:

| Effect | Examples | Default |
|---|---|---|
| Read | answer a question, describe the screen | Run |
| Navigate | switch app, tab, window; scroll; open a URL | Run |
| Local, reversible | type into a draft, toggle a view, rename with undo | Run, undo available |
| Local, irreversible | delete a file, close unsaved work, empty trash | Confirm |
| Visible to others | send, post, comment, share, invite, submit a form | Confirm with a one-line summary |
| Money, credentials, system | pay, change a password, security settings | Refuse by voice, or confirm twice |
| Shell | as today: dictated, read-only and not on the deny-list runs; anything else confirms | Confirm |

How the class is decided, in order:
1. **Deterministic rules first:** element role and label, the dialog it sits in ("Compose",
   "Delete…"), a per-app key-chord table (⌘↩ sends in chat and mail apps), app category
   (password managers and banking: no control), `CommandRiskChecker` for shell.
2. **Unknown buttons in dialogs count as visible-to-others** until known otherwise.
3. **Taint:** once a task has read screen or page content, anything visible-to-others or
   above is confirmed even if the user pre-approved the task (screen text can inject
   instructions; detectors catch little of it).
4. The LLM is only a tie-breaker, never the gate.

Confirmation is a spoken yes to a concrete summary. Silence never approves.

## 7. Memory and personalisation
- **Lexicon:** names, jargon, product words; learnt from corrections ("no, *Priya*") and
  from the screen; feeds Parakeet's custom vocabulary and the fast path's aliases.
- **Places and entities:** "the team channel" = Slack #growth; "work" = the
  boringworkflows.ai Chrome profile; "my notes" = a Notion page.
- **Habits:** which profile you use for which site, your usual terminal, preferred tab when
  several match. They break ties; they never override what you said.
- **Macros:** "start my day" = a list of verbs, or a macOS Shortcut (`shortcuts run`).
  Only saved when you say "save that as …"; re-checked by the effect policy every run.

## 8. Evaluation for "any use case"
1. **Intent and router suite (`router-eval`)** — every case also labelled with its intent
   kind and expected effect class. Add every misfire from the logs.
2. **Replay suite** — recorded sessions (audio, transcript, Screen Graph) replayed through
   L1–L4 against the recorded graph. No live apps needed; runs on every change.
3. **Live task suite** — OSWorld-style tasks on a test Mac account: set up a state, speak
   (TTS or recording), check the result (field value, URL, file).
4. **Persona suites, 20–30 tasks each** — marketer (Canva/Figma web, Sheets, LinkedIn
   draft), student (Docs, Notion, PDFs), designer (Figma, Finder), founder (Gmail, Calendar,
   Slack, Linear), developer (terminal, Claude Code, Cursor). Plus a **red-team set** of
   pages and docs with injected instructions; pass = nothing visible-to-others without a yes.

Release gate: dictation never lost, intent accuracy, task success per persona, confirmation
rate (too many confirmations kills the product), p50 end of speech → done.

## 9. Keep, change, replace

- **Keep:** speech stack and turn-taking; never consuming words on failure; per-snapshot
  IDs and rejecting unknown ones; verify after acting; `CommandRiskChecker`; secure-field
  refusal; `router-eval`; hints as data; the menu → accessibility → vision ladder.
- **Change:** ~30 tools → ~12 verbs; snapshot → Screen Graph; word-list safety → effect
  classes; `describe_screen` → the question path; `rewrite_draft` → edit mode (also for
  selected text); `ignore` removed from the router.
- **Add:** intent gate, fast path, agent loop, memory store, replay and persona suites.

## 10. Migration — each step ships and is usable

| Step | What | Done when |
|---|---|---|
| **1. Never lose words** | Intent gate v1: dictation by default, explicit triggers, "send it" position rule, remove `ignore`, ambiguous → typed with "that was a command" escape; hold-Fn unchanged | Replaying 3–4 Nov logs: zero dictated phrases dropped; every misfire typed or acted, none lost |
| **2. Screen Graph + verbs** | Places, menus and elements in one graph; router speaks verbs; existing adapters become drivers behind them | All 3–4 Nov navigation lines pass in replay; a new app (e.g. Notion) works with no code |
| **3. Effect policy** | Effect classes, key-chord table, taint; replaces tool-name tiers | Red-team set: no visible-to-others action without a yes; confirmation rate measured |
| **4. Edit and question paths** | Edit draft or selection; "what can I do here?" from the graph | "Make it more formal" works in Gmail, Slack, Notion; answers name real controls |
| **5. Fast path + memory** | No-LLM matches; lexicon and places learnt from corrections | p50 < 300 ms for matched commands; "team channel" resolves after one correction |
| **6. Agent loop** | Multi-step tasks with visible steps, screenshot fallback for inaccessible apps | Persona task suites at agreed success rates |
| **7. Personas and onboarding** | First-run that teaches by doing, "what can I say?", privacy screen | A non-technical tester completes 10 everyday tasks unaided |

Existing `PLAN.md` items map onto these steps (tab and terminal fixes are driver work in step
2; the menus-and-elements phase becomes step 2; voice dictation and draft editing become
steps 1 and 4; the terminal assistant is step 6).

## 11. Risks and open questions
1. **Inaccessible apps.** Only ~⅓ of apps expose a full accessibility tree; canvases expose
   nothing. Vision fallback is slow. → Measure an AX-quality score per app and route.
2. **Mode errors** — running dictation as a command is the most damaging everyday failure.
   → Bias to typing, explicit escapes, a visible mode badge.
3. **Agent latency** feels broken by voice. → Fast path first, batch actions, show steps,
   hard time budget then ask.
4. **Prompt injection** from what the agent reads. → Taint + confirmation; never let screen
   text trigger visible-to-others actions.
5. **Too many confirmations** make it useless; too few cause harm. → Deterministic rules,
   measure confirmation rate per persona.
6. **Chrome page accessibility** (`AXEnhancedUserInterface`) has side effects on window
   managers; spike `AXManualAccessibility` and an optional extension.
7. **Open: on-device versus cloud** for the intent gate and router (privacy, offline) —
   Apple's on-device model could take the fast path later.
8. **Open: pricing and platform** (Windows later?) — out of scope for this doc.

Spikes before step 2: Chrome page AX without side effects; `shortcuts run` latency; Screen
Graph build time on a busy Mac; intent-gate accuracy on the 3–4 Nov logs.

## 12. Sources
- Ruan et al., speech vs typing (IMWUT 2017): https://hci.stanford.edu/research/speech/paper.html
- Dhakal et al., 136M keystrokes (CHI 2018): https://userinterfaces.aalto.fi/136Mkeystrokes/
- Halverson et al., correction cascades (INTERACT 1999): https://dblp.dagstuhl.de/rec/conf/interact/HalversonHKK99.html
- Rambler, LLM-assisted dictation editing (CHI 2024): https://arxiv.org/abs/2401.10838
- Koenecke et al., ASR racial disparities (PNAS 2020): https://ideas.repec.org/a/nas/journl/v117y2020p7684-7689.html
- HBR, app toggling (2022): https://hbr.org/2022/08/how-much-time-and-energy-do-we-waste-toggling-between-applications
- Apple Voice Control modes: https://support.apple.com/en-gb/guide/mac-help/mh40719/mac
- Dragon recognition modes: https://www.nuance.com/products/help/dragon15/dragon-for-pc/enx/dpg-vla/Content/DragonBar/dragonbar_recognition_modes.htm
- Wispr Flow Command Mode: https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode
- Aqua Voice realtime / "send it": https://aquavoice.com/realtime
- Windows Voice Access 2025: https://blogs.windows.com/windowsexperience/2025/12/03/2025-a-year-in-recap-windows-accessibility/
- VoiceOS: https://www.voiceos.com
- UFO² (Microsoft): https://arxiv.org/html/2504.14603v2
- Agent S2: https://huggingface.co/papers/2504.00906
- OSWorld-Human latency: https://arxiv.org/html/2506.16042v1
- Claude computer use: https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool
- Claude Code computer use (tool precedence, per-app control): https://code.claude.com/docs/en/computer-use
- Screen2AX (macOS accessibility coverage): https://huggingface.co/papers/2507.16704
- UI action impact taxonomy: https://arxiv.org/pdf/2410.09006
- RedTeamCUA (prompt injection on computer-use agents): https://arxiv.org/html/2505.21936v5
- Prompt-injection design patterns: https://simonwillison.net/2025/Jun/13/prompt-injection-design-patterns/
- Agent Workflow Memory: https://arxiv.org/pdf/2409.07429v1.pdf
- OSWorld task checkers: https://timothyxxx.github.io/OSWorld/user_guides/task_example_explanation.html
- Agent trust study (2026 preprint): https://arxiv.org/abs/2607.18257
