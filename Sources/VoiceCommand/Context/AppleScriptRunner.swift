import Foundation

/// All AppleScript runs on this one serial thread (Final review point 18). The first
/// Automation prompt for an app blocks it, which is why onboarding warms each target.
final class AppleScriptRunner: NSObject {
    static let shared = AppleScriptRunner()

    struct ScriptError: Error, CustomStringConvertible {
        let number: Int
        let message: String
        var description: String { "AppleScript error \(number): \(message)" }
        static let timeout = ScriptError(number: -1712, message: "timed out")
        var isPermissionDenied: Bool { number == -1743 }
    }

    private var thread: Thread!
    private var compiled: [String: NSAppleScript] = [:]   // touched only on `thread`

    private final class Box: NSObject {
        let block: () -> Void
        init(_ b: @escaping () -> Void) { block = b }
    }

    private override init() {
        super.init()
        let t = Thread { [weak self] in
            _ = self
            // A port keeps the run loop alive so perform(_:on:) can deliver work.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            while true { RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
        t.name = "VoiceCommand.AppleScript"
        t.qualityOfService = .userInitiated
        t.start()
        thread = t
    }

    @objc private func runBox(_ box: Box) { box.block() }

    /// Run a block on the AppleScript thread.
    func async(_ block: @escaping () -> Void) {
        perform(#selector(runBox(_:)), on: thread, with: Box(block), waitUntilDone: false)
    }

    /// Synchronous execution; must already be on the AppleScript thread.
    func executeHere(_ source: String) -> Result<NSAppleEventDescriptor, ScriptError> {
        let script: NSAppleScript
        if let s = compiled[source] { script = s } else {
            guard let s = NSAppleScript(source: source) else { return .failure(ScriptError(number: -2700, message: "could not compile")) }
            var err: NSDictionary?
            s.compileAndReturnError(&err)
            if let err { return .failure(Self.error(err)) }
            // Snapshot queries repeat verbatim; one-off scripts (typed text) don't, so bound it.
            if compiled.count > 64 { compiled.removeAll() }
            compiled[source] = s
            script = s
        }
        var err: NSDictionary?
        let out = script.executeAndReturnError(&err)
        if let err { return .failure(Self.error(err)) }
        return .success(out)
    }

    /// Run a script with a deadline. Past the deadline the caller gets `.timeout`; the
    /// thread finishes the script in the background (Apple events cannot be interrupted).
    func run(_ source: String, timeout: TimeInterval = 0.5) async -> Result<NSAppleEventDescriptor, ScriptError> {
        await withCheckedContinuation { (cont: CheckedContinuation<Result<NSAppleEventDescriptor, ScriptError>, Never>) in
            let lock = NSLock()
            var done = false
            func finish(_ r: Result<NSAppleEventDescriptor, ScriptError>) {
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                cont.resume(returning: r)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(.failure(.timeout)) }
            async { finish(self.executeHere(source)) }
        }
    }

    /// Run and return the result as a string (lists are joined by the script itself).
    func runString(_ source: String, timeout: TimeInterval = 0.5) async -> Result<String, ScriptError> {
        (await run(source, timeout: timeout)).map { $0.stringValue ?? "" }
    }

    private static func error(_ dict: NSDictionary) -> ScriptError {
        ScriptError(number: dict[NSAppleScript.errorNumber] as? Int ?? -1,
                    message: dict[NSAppleScript.errorMessage] as? String ?? "unknown")
    }

    /// Escape a Swift string for use inside an AppleScript string literal.
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
