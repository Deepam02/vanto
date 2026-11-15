import Foundation
import VoiceCommandCore

// intent-eval: runs the local intent gate over hand-labelled speech (the logged utterances
// plus written persona examples) and prints per-class precision and recall. No API calls.
// Fails (exit 1) if any command is certain dictation, any dictation a certain command, or
// any background speech is typed (docs/specs/never-lose-dictation.md §7.2).
//
// Usage: intent-eval [--set path] [--verbose]

var setPath = "Tools/intent-eval/labelled-utterances.json"
var verbose = false
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--set": setPath = args.next() ?? setPath
    case "--verbose", "-v": verbose = true
    case "--help", "-h":
        print("usage: intent-eval [--set path] [--verbose]")
        exit(0)
    default:
        FileHandle.standardError.write("unknown argument \(a)\n".data(using: .utf8)!)
        exit(2)
    }
}

let cases: [IntentEval.Case]
do { cases = try IntentEval.load(URL(fileURLWithPath: setPath)) } catch {
    FileHandle.standardError.write("could not read \(setPath): \(error)\n".data(using: .utf8)!)
    exit(1)
}

let report = IntentEval.run(cases)
print(IntentEval.render(report))
if verbose {
    // Every decision in the first context, for reading through the misses.
    let ctx = IntentEval.contexts[0]
    print("\n## Decisions in \(ctx.name)")
    for c in cases {
        let d = IntentGate.decide(c.text, ctx.context)
        print("\(c.id) [\(c.label)] \(d.logLine) — \(c.text.prefix(80))")
    }
}
exit(report.violations.isEmpty ? 0 : 1)
