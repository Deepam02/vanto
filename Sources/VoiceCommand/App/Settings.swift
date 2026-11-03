import Foundation
import Security
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Carbon fallback chord, always registered next to Fn (Cursor's Secure Input leak can
    /// silently disable event taps).
    static let toggleSession = Self("toggleSession", initial: .init(.space, modifiers: [.control, .option]))
}

/// User settings, persisted in UserDefaults. The API key lives in the Keychain.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    /// Fixed commit delay before routing a finished phrase (Final review point 9: ~450 ms).
    @Published var commitDelayMs: Int { didSet { d.set(commitDelayMs, forKey: "commitDelayMs") } }
    /// Idle timeout, 20 s – 5 min, counting idle time only.
    @Published var idleTimeoutSec: Int { didSet { d.set(idleTimeoutSec, forKey: "idleTimeoutSec") } }
    @Published var fnKeyEnabled: Bool { didSet { d.set(fnKeyEnabled, forKey: "fnKeyEnabled") } }
    /// Default input is the built-in mic even when AirPods are the output.
    @Published var useBuiltInMic: Bool { didSet { d.set(useBuiltInMic, forKey: "useBuiltInMic") } }
    @Published var thinkingPauses: Bool { didSet { d.set(thinkingPauses, forKey: "thinkingPauses") } }

    static let hardSessionCapSec = 600

    private init() {
        d.register(defaults: [
            "commitDelayMs": 450, "idleTimeoutSec": 20, "fnKeyEnabled": true,
            "useBuiltInMic": true, "thinkingPauses": true,
        ])
        commitDelayMs = d.integer(forKey: "commitDelayMs")
        idleTimeoutSec = d.integer(forKey: "idleTimeoutSec")
        fnKeyEnabled = d.bool(forKey: "fnKeyEnabled")
        useBuiltInMic = d.bool(forKey: "useBuiltInMic")
        thinkingPauses = d.bool(forKey: "thinkingPauses")
    }
}

/// Anthropic API key in the login Keychain (service "VoiceCommand", account "anthropic-api-key").
/// In debug builds the ANTHROPIC_API_KEY environment variable overrides it.
enum APIKeyStore {
    static let service = "VoiceCommand"
    static let account = "anthropic-api-key"

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let key = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !trimmed.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrLabel as String] = "VoiceCommand Anthropic API key"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
