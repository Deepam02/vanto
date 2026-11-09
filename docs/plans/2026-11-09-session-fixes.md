# Fixes from the 9 Nov sessions — plan

Source: `~/Library/Logs/VoiceCommand/commands.jsonl`, 9 Nov 18:56–19:05, two sessions,
60 commands (log rows 366–435). Status: built on fix/nov9-sessions; see PROGRESS.md.

Scope rule: every change here is small, sits on today's architecture, and leaves room for
the two specs (`never-lose-dictation`, `memory-and-learning`). Nothing here adds an intent
gate, a dictate tool, a kept store or a memory store.

## What went well (keep it)

- Several things in one breath: "pause that video and go back to YouTube" (386) → click
  Pause + switch tab; "next and next video" (398) → two clicks. Volume up / set 52 / full,
  pause video, next / previous, close tab, `cmd+shift+t` after a correction (394),
  `rewrite_draft` "make it sharper and more Twitter friendly" (415, 417).
- Speech end → action: median ~3.4 s, of which ~2.0 s is the end-of-speech pause. Accuracy
  first, so the pause is not touched here.

## What went wrong, by root cause

Reading between the lines: the session was a real non-developer task (watch a song on
YouTube, post on X). It broke in four places, each with one root cause — not one-off bugs.

### A. The speech vocabulary turns everyday words into developer words
| Row | Said (likely) | Heard | Effect |
|---|---|---|---|
| 374 | "fifty-two percent" | "fifty-two **Vercel**" | worked by luck |
| 419 | "make the post" | "**Mkdir** post" | asked "what should the post be?" |
| 428 | "make the volume full" | "**Mkdir** volume full" | typed `mkdir volume full` into a terminal, asked to run it |
| 431 | "make it one hundred percent" | "**Mkdir** one hundred **Vercel**" | asked about a folder |
| 404, 423, 432 | "message" | "**Messages**" | 432 typed "yeah, push it for me" **into the Messages app** |
| 434–435 | "end session" | "**Henderson**" | see G |

Cause: `SpeechEngine.baseVocabulary` boosts "Vercel"; `spokenAliases` maps "make dir" →
`mkdir` (so "make the" / "make it" becomes `mkdir`); every running app name is boosted,
including plain English ones (Messages, Notes, Music, Mail, Photos, Maps, News, Books,
Preview, Reminders, Calendar…). The log keeps only the boosted text, so we can't see what
the plain model heard.

### B. The router gets one look; anything after "go there" is dropped
| Row | Said | Did | Missing |
|---|---|---|---|
| 368 | "zoom in a bit" | describe_screen | the zoom |
| 376 | "what can you do on this page" | describe_screen | no answer spoken |
| 384 | "…it was YouTube… open the Senorita song" | switched tab | opening the song |
| 388 | "go back to YouTube and inside YouTube open this video" | switched tab | opening the video |
| 401 | "go to X… and search for latest news" | switched tab | the search |

Cause: `route()` runs a single streamed reply. Tool results never go back to the model, so
it can't act on a page it hasn't seen yet, and `describe_screen` ends the turn.

### C. "Send" and "Post" on web pages aren't checked
- 418 "Send this post" → `submit` pressed Return in X's box (Chrome's hint is `return`; X
  needs ⌘↩ or the Post button) and reported "Sent". The draft was then dropped.
- 421, 423: "click the post button… the one in the centre, not the sidebar" → clicked the
  sidebar "Post" twice. `UIAdapter.click` takes the first visible match in tree order and
  has no way to say which one. 424: "Nah, you are still not getting it. Close the session."

### D. Writing for the person is blocked, and instructions get typed
- 405 "write a very nice post announcing yourself, you are Vanto" → the router wrote a good
  post; `ActionPolicy` rejected it because `type_text` must match the transcript word for
  word.
- 402 "make a post for me? Post like I have figured it out" → typed "Post like I have
  figured it out" (the instruction word went in).
- 406–410: so the person had to dictate it, which came out garbled ("Scraping… and S. Just
  dark"). They said: "I think your drafting feature is still not good."
- 412 "go back" → `clear_typed` **and** `undo_last` (two removals for one request).

### E. Browser tabs: no "previous", no "reopen", search leaves the site
- 381 "go back to the previous tab" → browser Back. 382 → switched to Netflix; the tab they
  had just left was YouTube.
- 393 "reopen the YouTube you closed" → opened a fresh youtube.com (it took a second request
  to get ⌘⇧T).
- 378, 387 "open the Senorita video" while on YouTube → a Google search, not YouTube's.

### F. Clicks that should have worked
- 389 "I can see Saheba, Finding Her, I Am Done — open I Am Done" → "No 'I Am Done' on screen".
  Video titles on YouTube's grid weren't found in the 1.5 s element budget.
- 399, 400 "previous video" → the Previous button had gone (YouTube shows it only
  sometimes), though its label said "Previous (SHIFT+p)" — the shortcut was right there.

### G. "End the session" didn't end it
- 435 "Henderson. Uh End the session." → `wait_for_more`. The person used the hotkey.

### Smaller
- 366 "open Floyd" → "I don't see Floyd. Did you mean Finder, Slack?" — Claude was running.
  Left to the memory spec (it learns "Floyd" → Claude after one correction).
- 385, 414: a turn that newer speech cancelled had already acted (switched to Netflix,
  typed text). It came out right, because the next turn saw the result. Check only.

## The plan — seven small changes, one PR ("Fixes from the 9 Nov sessions")

Order is by harm × ease. Each step lands with tests and new golden-set cases taken from the
rows above.

### 1. Vocabulary: stop boosting words people say every day (A)
- Remove "Vercel" from `baseVocabulary` and the `mkdir` alias entry (`"make dir"` collides
  with "make the / make it"). Keep "mkdir" out of boosting entirely; "make a folder called
  X" already routes to `terminal_run` composed.
- Running app names: boost only distinctive ones. Reuse `ScreenVocabulary`'s rule: skip an
  app whose name is a common English word (new list in Core: Messages, Notes, Mail, Music,
  Photos, Maps, News, Books, Preview, Reminders, Calendar, Contacts, Clock, Weather,
  Stocks, Home, Podcasts, TV, Shortcuts, Finder…). The router still sees every app in the
  snapshot, so "open Notes" keeps working without boosting.
- Log both texts: add `rawTranscript` (before boosting) next to `transcript` in
  `CommandRecord`. This is what told us A happened, and the memory spec's correction
  detector needs it too.
- Test: a Core unit test that the default vocabulary contains none of a list of common
  words; router-eval cases for 419/428/431/432 as heard, expecting no `terminal_run` and no
  Messages target.
- Fits the memory spec: that spec learns a person's own terms; this only removes wrong
  defaults, and keeps command aliases away from ordinary speech (its scope rule).

### 2. End the session locally (G)
- Before routing, if the transcript's **last clause** is an explicit end phrase ("end / close
  / stop the session", "stop listening", "that's all"), end it locally, as the mute phrases
  already are. Leading filler or a misheard word ("Henderson. Uh…") doesn't block it.
- One phrase list in Core, shared with the dictation spec's end phrases later.
- Test: unit tests for the matcher, including 435 and "don't end the session yet" (must not end).

### 3. Send that is checked, and the right button (C)
- After `submit`, read the draft's text box again. If our text is still there, it wasn't
  sent: try the page's send button — the button nearest the text box whose name is a send
  word (Post, Send, Reply, Tweet, Submit, Comment) — and report what really happened.
  Never say "Sent" without that check. Keep the draft until it's confirmed gone.
- `click_element` with several matches: prefer the one nearest the draft or focused text
  box, then the one nearest the window centre, and add an optional `near` argument
  ("text box", "sidebar", "top", "centre") the router fills from words like "the one in
  the centre, not the sidebar".
- Test: Core tests for "nearest match" ranking; action-script case for X compose.
- Generic on purpose: no X-specific code; it works for any web composer.

### 4. Let the router write when asked (D)
- `type_text` gets `source: verbatim | composed`, like `terminal_run` already has.
  `composed` is allowed only when the transcript asks for writing ("write", "draft",
  "compose", "make a post/reply/email", "something nice about"). Composed text is typed as
  a draft, shown in the HUD as "Written for you", and never sent without a spoken send
  (the existing gate).
- Verbatim stays strict, and the payload is what follows "saying / like / that says"
  (402 → "I have figured it out"); add router examples for both.
- One removal per request: "go back" / "undo that" right after typing → `clear_typed` only,
  never with `undo_last` too (rule in the router and `ActionPolicy`).
- Fits the dictation spec: that spec owns **your** words (dictation); this is the router
  writing on request, into the same `Draft`, so "make it sharper" and "send" work the same.

### 5. Browser tabs: recent, reopen, search in the site (E)
- Keep a per-session order of tab activations (we already have stable tab ids) and give the
  router `recent_tabs` (last 3) in the snapshot. Rule: "previous tab / the tab I was on /
  go back to <site>" → most recent matching tab, not browser Back.
- Rule + example: "reopen the tab I/you closed" → `press_keys cmd+shift+t`.
- "Search for X" / "open the X video" while a site is in front: search **in the site** —
  focus the page's search field (an AX search field or text field named Search in the web
  area), type, Return. Fall back to the current `browser_search`. No per-site URL list.

### 6. Clicks: shortcut fallback and a deeper second look (F)
- Remember shortcuts seen in element names this session ("Previous (SHIFT+p)"). When a click
  on that name fails, press the shortcut.
- On a miss, look again with a larger budget (3 s, more elements) and match against link
  and heading text inside the web area — accuracy over speed. Reproduce 389 with an
  action-script case on a YouTube grid first, so we fix the real cause rather than a guess.

### 7. A second look after moving (B) — the largest change
- New tool `look_again(reason)`: the router calls it last when the rest of the request
  depends on a screen it hasn't seen ("go to X and search", "go to YouTube and open this
  video"). `describe_screen` counts as `look_again` too.
- After the reply finishes, if one was called: wait for the page to settle (≤ 1 s), take a
  fresh snapshot, and run one more router turn with "Already done: …" plus the new
  screen. At most 2 extra turns per request; newer speech still cancels.
- For "what can you do on this page" the second turn answers with `say`; for "zoom in" it
  acts.
- Test: router-eval cases 368, 376, 384, 388, 401 as two-turn scenarios (the eval runner
  gains a "second screen" fixture).
- Fits both specs: the dictation spec's "carry the content through" and the memory spec's
  context block go into the same `RouterInput`, which this only calls twice.

## Not in this plan (belongs to the specs)
- Words lost when routed to `ignore`, stale buffer, session end → dictation spec.
- Learning "Floyd" = Claude, "Henderson" = end session, preferred tabs → memory spec.
- The 2 s end-of-speech pause → separate latency work, only if accuracy holds.

## Done when
- Unit tests and router-eval pass (≥ 90%, with the new 9 Nov cases added).
- Replaying today's transcripts through router-eval gives the right tools for rows 368, 376,
  381, 382, 384, 388, 393, 401, 402, 405, 412, 419, 428, 431, 432, 435.
- One live run of today's two tasks (YouTube song, X post) by voice only.
