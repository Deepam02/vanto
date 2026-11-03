import Foundation
import VoiceCommandCore

// log-report: turns ~/Library/Logs/VoiceCommand/commands.jsonl into the PRD's
// success-criteria table (M7 acceptance).
//
// Usage: log-report [path/to/commands.jsonl]

let path = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) } ?? CommandLog.defaultURL
do {
    let summary = try LogReport.load(path)
    print("Success criteria from \(path.path)\n")
    print(LogReport.render(summary))
} catch {
    FileHandle.standardError.write("could not read \(path.path): \(error)\n".data(using: .utf8)!)
    exit(1)
}
