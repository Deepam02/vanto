import Foundation

public enum RouterError: Error, Equatable, CustomStringConvertible {
    case missingAPIKey
    case network(String)
    case rateLimited          // 429
    case overloaded           // 529
    case http(Int, String)
    case timeout
    case refusal
    case noToolCall
    case truncated            // stop_reason max_tokens with an open tool call
    case incomplete(String)   // the stream ended before message_stop (details for the log)

    public var description: String {
        switch self {
        case .missingAPIKey: return "No API key set"
        case .network(let m): return "No network (\(m))"
        case .rateLimited: return "Claude API rate limit hit (429)"
        case .overloaded: return "Claude API overloaded (529)"
        case .http(let code, let m): return "Claude API error \(code): \(m)"
        case .timeout: return "Router didn't answer in time"
        case .refusal: return "Claude declined this request"
        case .noToolCall: return "Didn't catch that"
        case .truncated: return "Router reply was cut off"
        case .incomplete(let m): return "Router reply ended early (\(m))"
        }
    }

    /// One short line for the HUD.
    public var hudMessage: String {
        switch self {
        case .missingAPIKey: return "Add your Anthropic API key in Settings"
        case .network: return "No network — nothing ran"
        case .rateLimited: return "Rate limited (429) — nothing ran"
        case .overloaded: return "Claude is overloaded (529) — nothing ran"
        case .http(let code, _): return "API error \(code) — nothing ran"
        case .timeout: return "No reply in time — nothing ran"
        case .refusal: return "Claude declined that request"
        case .noToolCall: return "Didn't catch that"
        case .truncated: return "Reply was cut off — nothing ran"
        case .incomplete: return "Reply ended early — nothing ran"
        }
    }
}

/// A streamed event from one router call.
public enum RouterEvent: Sendable {
    case toolStarted(index: Int, name: String, at: Date)
    case firstInputDelta(index: Int, at: Date)
    case toolCompleted(index: Int, name: String, call: Result<ToolCall, ToolCall.ParseError>, rawInput: String, at: Date)
    case text(String)
    case finished(stopReason: String?, usage: Usage)
}

public struct Usage: Codable, Equatable, Sendable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadInputTokens = 0
    public var cacheCreationInputTokens = 0
    public init() {}
}

/// Minimal Messages API client over URLSession + server-sent events. No third-party SDK.
public final class ClaudeClient: @unchecked Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2026-10-21"

    private var _session: URLSession
    private let sessionLock = NSLock()
    private var session: URLSession { sessionLock.withLock { _session } }
    private let config: URLSessionConfiguration
    public var apiKey: String?
    /// Sent as `anthropic-workspace-id`; needed only for keys not scoped to a workspace.
    public var workspaceID: String?

    public init(apiKey: String?, workspaceID: String? = nil) {
        self.apiKey = apiKey
        self.workspaceID = workspaceID
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        self.config = config
        // One session for the app's lifetime keeps the HTTP/2 connection warm.
        self._session = URLSession(configuration: config)
    }

    /// Drop the warm connection and start a new one: used before retrying a reply that
    /// ended early, in case the reused HTTP/2 connection was the problem (4 Nov log).
    public func resetConnection() {
        let fresh = URLSession(configuration: config)
        let old = sessionLock.withLock { () -> URLSession in
            let o = _session
            _session = fresh
            return o
        }
        old.finishTasksAndInvalidate()
    }

    private func request(body: [String: Any]) throws -> URLRequest {
        guard let key = apiKey, !key.isEmpty else { throw RouterError.missingAPIKey }
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if let ws = workspaceID?.trimmingCharacters(in: .whitespaces), !ws.isEmpty {
            req.setValue(ws, forHTTPHeaderField: "anthropic-workspace-id")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    /// Opens the TLS/HTTP2 connection and writes the cached prefix, so the first real
    /// command pays neither. A `max_tokens: 0` call runs prefill only (cache pre-warming)
    /// with the same thinking/effort/tools as real traffic, so the cached prefix matches.
    public func warmUp() async {
        let input = RouterInput(history: "", snapshot: DesktopSnapshot(), transcript: "(warm-up, no speech yet)")
        let body = RouterPrompt.requestBody(input, maxTokens: 0, stream: false)
        guard let req = try? request(body: body) else { return }
        _ = try? await session.data(for: req)
    }

    /// Stream one router call. Tool calls are emitted as soon as their input block closes.
    public func route(_ input: RouterInput) -> AsyncThrowingStream<RouterEvent, Error> {
        let body = RouterPrompt.requestBody(input)
        return stream(body: body)
    }

    public func stream(body: [String: Any]) -> AsyncThrowingStream<RouterEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try self.request(body: body)
                    let (bytes, response) = try await self.session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else { throw RouterError.network("no HTTP response") }
                    if http.statusCode != 200 {
                        var text = ""
                        for try await line in bytes.lines { text += line; if text.count > 2000 { break } }
                        switch http.statusCode {
                        case 429: throw RouterError.rateLimited
                        case 529: throw RouterError.overloaded
                        default: throw RouterError.http(http.statusCode, Self.errorMessage(text))
                        }
                    }
                    var parser = SSEToolParser()
                    var lines = 0, head = ""
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        lines += 1
                        if head.count < 300 { head += line.prefix(300 - head.count) + "⏎" }
                        for event in parser.consume(line: line) { continuation.yield(event) }
                        if parser.finished { break }
                    }
                    // No message_stop: say what did arrive, so the log shows the cause.
                    if !parser.finished {
                        let type = http.value(forHTTPHeaderField: "content-type") ?? "?"
                        let rid = http.value(forHTTPHeaderField: "request-id") ?? "?"
                        throw RouterError.incomplete("HTTP \(http.statusCode), \(type), \(lines) lines, request-id \(rid), starts: \(head.isEmpty ? "(empty)" : head)")
                    }
                    continuation.finish()
                } catch let e as RouterError {
                    continuation.finish(throwing: e)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let e as URLError {
                    if e.code == .cancelled { continuation.finish(throwing: CancellationError()) }
                    else if e.code == .timedOut { continuation.finish(throwing: RouterError.timeout) }
                    else { continuation.finish(throwing: RouterError.network(e.localizedDescription)) }
                } catch {
                    continuation.finish(throwing: RouterError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func errorMessage(_ body: String) -> String {
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
            return msg
        }
        return String(body.prefix(200))
    }
}

/// Incremental parser for the Messages SSE stream, tracking tool_use blocks.
public struct SSEToolParser {
    private var blocks: [Int: (name: String, json: String, sawDelta: Bool)] = [:]
    private var stopReason: String?
    private var usage = Usage()
    public private(set) var finished = false

    public init() {}

    public mutating func consume(line: String) -> [RouterEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return [] }
        let now = Date()

        switch type {
        case "message_start":
            if let msg = obj["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] {
                usage.inputTokens = u["input_tokens"] as? Int ?? 0
                usage.cacheReadInputTokens = u["cache_read_input_tokens"] as? Int ?? 0
                usage.cacheCreationInputTokens = u["cache_creation_input_tokens"] as? Int ?? 0
            }
        case "content_block_start":
            guard let index = obj["index"] as? Int, let block = obj["content_block"] as? [String: Any] else { break }
            if block["type"] as? String == "tool_use", let name = block["name"] as? String {
                blocks[index] = (name, "", false)
                return [.toolStarted(index: index, name: name, at: now)]
            }
        case "content_block_delta":
            guard let index = obj["index"] as? Int, let delta = obj["delta"] as? [String: Any] else { break }
            switch delta["type"] as? String {
            case "input_json_delta":
                guard var b = blocks[index] else { break }
                b.json += delta["partial_json"] as? String ?? ""
                let first = !b.sawDelta
                b.sawDelta = true
                blocks[index] = b
                if first { return [.firstInputDelta(index: index, at: now)] }
            case "text_delta":
                if let t = delta["text"] as? String { return [.text(t)] }
            default: break
            }
        case "content_block_stop":
            guard let index = obj["index"] as? Int, let b = blocks[index] else { break }
            let result: Result<ToolCall, ToolCall.ParseError>
            do { result = .success(try ToolCall.parse(name: b.name, inputJSON: b.json)) }
            catch let e as ToolCall.ParseError { result = .failure(e) }
            catch { result = .failure(.invalidInput("\(error)")) }
            return [.toolCompleted(index: index, name: b.name, call: result, rawInput: b.json, at: now)]
        case "message_delta":
            if let d = obj["delta"] as? [String: Any], let r = d["stop_reason"] as? String { stopReason = r }
            if let u = obj["usage"] as? [String: Any], let out = u["output_tokens"] as? Int { usage.outputTokens = out }
        case "message_stop":
            finished = true
            return [.finished(stopReason: stopReason, usage: usage)]
        case "error":
            finished = true
            let e = obj["error"] as? [String: Any]
            let etype = e?["type"] as? String ?? "error"
            if etype == "overloaded_error" { return [.finished(stopReason: "overloaded", usage: usage)] }
            return [.finished(stopReason: "error:\(e?["message"] as? String ?? etype)", usage: usage)]
        default: break
        }
        return []
    }
}
