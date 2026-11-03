import Foundation
import VoiceCommandCore

// router-eval: runs the golden set against the Claude API and prints accuracy and
// p50/p90 time to first tool call (M3 acceptance: ≥ 90% correct, p50 ≤ 600 ms).
//
// Usage: router-eval [--set path] [--filter substr] [--repeat N] [--verbose]
// Needs ANTHROPIC_API_KEY in the environment (and ANTHROPIC_WORKSPACE_ID for keys that
// aren't scoped to a workspace).

struct Options {
    var setPath = "Tools/router-eval/golden-set.json"
    var filter: String?
    var repeatCount = 1
    var verbose = false
}

func parseOptions() -> Options {
    var o = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let a = args.next() {
        switch a {
        case "--set": o.setPath = args.next() ?? o.setPath
        case "--filter": o.filter = args.next()
        case "--repeat": o.repeatCount = Int(args.next() ?? "1") ?? 1
        case "--verbose", "-v": o.verbose = true
        case "--help", "-h":
            print("usage: router-eval [--set path] [--filter substr] [--repeat N] [--verbose]")
            exit(0)
        default:
            FileHandle.standardError.write("unknown argument \(a)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return o
}

struct RunResult {
    var calls: [RawCall] = []
    var ttftMs: Int?
    var totalMs: Int = 0
    var stopReason: String?
    var usage: Usage?
    var error: String?
    var text = ""
}

func runOnce(_ client: ClaudeClient, _ input: RouterInput) async -> RunResult {
    var r = RunResult()
    let start = Date()
    do {
        for try await ev in client.route(input) {
            switch ev {
            case .toolStarted(_, _, let at):
                if r.ttftMs == nil { r.ttftMs = Int(at.timeIntervalSince(start) * 1000) }
            case .toolCompleted(_, let name, _, let raw, _):
                r.calls.append(RawCall(name: name, inputJSON: raw))
            case .text(let t): r.text += t
            case .finished(let stop, let usage):
                r.stopReason = stop; r.usage = usage
            case .firstInputDelta: break
            }
        }
    } catch {
        r.error = "\(error)"
    }
    r.totalMs = Int(Date().timeIntervalSince(start) * 1000)
    return r
}

func percentile(_ xs: [Int], _ p: Double) -> Int? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return s[Int((Double(s.count - 1) * p).rounded())]
}

let opts = parseOptions()
guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
    FileHandle.standardError.write("ANTHROPIC_API_KEY is not set\n".data(using: .utf8)!)
    exit(2)
}

let set: GoldenSet
do { set = try GoldenSet.load(URL(fileURLWithPath: opts.setPath)) } catch {
    FileHandle.standardError.write("could not load \(opts.setPath): \(error)\n".data(using: .utf8)!)
    exit(2)
}

let cases = set.cases.filter { c in opts.filter.map { c.id.contains($0) } ?? true }
let client = ClaudeClient(apiKey: key, workspaceID: ProcessInfo.processInfo.environment["ANTHROPIC_WORKSPACE_ID"])

print("router-eval: \(cases.count) cases × \(opts.repeatCount), model \(RouterPrompt.model)")
await client.warmUp()

var passed = 0, total = 0
var ttfts: [Int] = []
var totals: [Int] = []
var cacheReads = 0
var failures: [String] = []

for round in 0..<opts.repeatCount {
    for c in cases {
        let input = c.routerInput(fixtures: set.fixtures)
        var r = await runOnce(client, input)
        // Same behaviour as the app: one retry when the reply has no tool call.
        if r.error == nil && r.calls.isEmpty && r.stopReason != "refusal" {
            r = await runOnce(client, input)
        }
        total += 1
        if let t = r.ttftMs { ttfts.append(t) }
        totals.append(r.totalMs)
        cacheReads += r.usage?.cacheReadInputTokens ?? 0

        var verdict = Grader.grade(c, calls: r.calls, fixtures: set.fixtures)
        if let e = r.error { verdict.pass = false; verdict.reasons.insert("error: \(e)", at: 0) }
        if verdict.pass { passed += 1 }
        let calls = r.calls.map { call -> String in
            let parsed = (try? ToolCall.parse(name: call.name, input: call.input))?.summary ?? call.name + "(unparseable)"
            return parsed
        }.joined(separator: " ; ")
        let tag = verdict.pass ? "PASS" : "FAIL"
        let prefix = opts.repeatCount > 1 ? "[\(round + 1)] " : ""
        let idCol = c.id.padding(toLength: 28, withPad: " ", startingAt: 0)
        let ms = (r.ttftMs.map(String.init) ?? "-")
        let msCol = String(repeating: " ", count: max(0, 5 - ms.count)) + ms
        print("\(prefix)\(tag) \(idCol) \(msCol) ms  \(calls)")
        if !verdict.pass {
            for reason in verdict.reasons { print("       ↳ \(reason)") }
            failures.append(c.id)
        }
        if opts.verbose {
            print("       usage: in \(r.usage?.inputTokens ?? 0), cache read \(r.usage?.cacheReadInputTokens ?? 0), cache write \(r.usage?.cacheCreationInputTokens ?? 0), out \(r.usage?.outputTokens ?? 0), stop \(r.stopReason ?? "-")")
            if !r.text.isEmpty { print("       text: \(r.text)") }
        }
    }
}

let accuracy = total == 0 ? 0 : Double(passed) / Double(total) * 100
let p50 = percentile(ttfts, 0.5), p90 = percentile(ttfts, 0.9)
print("")
print(String(format: "accuracy: %.1f%% (%d/%d)", accuracy, passed, total))
print("time to first tool call: p50 \(p50.map { "\($0) ms" } ?? "n/a"), p90 \(p90.map { "\($0) ms" } ?? "n/a")")
print("full reply: p50 \(percentile(totals, 0.5).map { "\($0) ms" } ?? "n/a"), p90 \(percentile(totals, 0.9).map { "\($0) ms" } ?? "n/a")")
print("cache read tokens: \(cacheReads)")
if !failures.isEmpty { print("failed: \(failures.joined(separator: ", "))") }
let ok = accuracy >= 90 && (p50 ?? Int.max) <= 600
print(ok ? "M3 acceptance: PASS" : "M3 acceptance: FAIL (needs ≥ 90% and p50 ≤ 600 ms)")
exit(ok ? 0 : 1)
