# Progress

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
