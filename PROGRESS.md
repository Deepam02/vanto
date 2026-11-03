# Progress

Status of each PRD milestone. "Verified" means checked on this machine by me; "needs you"
means it can only be accepted with a person at the Mac (permissions, microphone, real apps).

| Milestone | Built | Verified here | Acceptance still needs you |
| --- | --- | --- | --- |
| M0 shell and permissions | ✅ | builds, signs, launches | Fresh install to "all green" in < 2 min |
| M1 audio and live transcript | ✅ | pipeline on synthetic speech (see below) | Real mic, AirPods unplug/replug, 30-min footprint |
| M2 context snapshot | ✅ | builds | Debug window updates within 1 s |
| M3 router and eval | ✅ | unit tests; eval pending your API key | `router-eval` ≥ 90% and p50 ≤ 600 ms |
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
