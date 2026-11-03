import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics

/// Status of every permission the app uses, plus the Globe-key setting (M0).
final class Permissions: ObservableObject {
    enum Status: Equatable {
        case granted, denied, notDetermined, notRunning, notNeeded
        var isGreen: Bool { self == .granted || self == .notNeeded }
        var label: String {
            switch self {
            case .granted: return "Granted"
            case .denied: return "Denied"
            case .notDetermined: return "Not yet asked"
            case .notRunning: return "App not running"
            case .notNeeded: return "Not needed"
            }
        }
    }

    struct AutomationTarget: Identifiable {
        let name: String
        let bundleID: String
        var id: String { bundleID }
    }

    static let automationTargets = [
        AutomationTarget(name: "Google Chrome", bundleID: "com.google.Chrome"),
        AutomationTarget(name: "Terminal", bundleID: "com.apple.Terminal"),
        AutomationTarget(name: "iTerm2", bundleID: "com.googlecode.iterm2"),
        AutomationTarget(name: "Ghostty", bundleID: "com.mitchellh.ghostty"),
    ]

    @Published var microphone: Status = .notDetermined
    @Published var accessibility: Status = .notDetermined
    @Published var inputMonitoring: Status = .notDetermined
    @Published var screenRecording: Status = .notNeeded
    @Published var automation: [String: Status] = [:]
    @Published var globeKeyDoesNothing = false
    @Published var apiKeySet = false

    /// Installed automation targets (uninstalled terminals are not required).
    var installedTargets: [AutomationTarget] {
        Self.automationTargets.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    var allGreen: Bool {
        microphone.isGreen && accessibility.isGreen && inputMonitoring.isGreen && apiKeySet &&
            installedTargets.allSatisfy { (automation[$0.bundleID] ?? .notDetermined).isGreen || automation[$0.bundleID] == .notRunning }
    }

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notDetermined
        default: microphone = .denied
        }
        accessibility = AXIsProcessTrusted() ? .granted : .denied
        inputMonitoring = CGPreflightListenEventAccess() ? .granted : .denied
        // Final review point 6: Accessibility gives window titles and the screenshot path is
        // cut, so Screen Recording is shown for information only.
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .notNeeded
        let fnUsage = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
        globeKeyDoesNothing = fnUsage == 0
        apiKeySet = APIKeyStore.load() != nil
        for t in installedTargets {
            let target = t
            AppleScriptRunner.shared.async {
                let s = Self.automationStatus(bundleID: target.bundleID, ask: false)
                DispatchQueue.main.async { self.automation[target.bundleID] = s }
            }
        }
    }

    /// AEDeterminePermissionToAutomateTarget. With `ask`, shows the Automation prompt; this
    /// blocks, so it only ever runs on the AppleScript thread.
    static func automationStatus(bundleID: String, ask: Bool) -> Status {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else { return .notRunning }
        var desc = AEAddressDesc()
        let id = bundleID.data(using: .utf8)!
        let created = id.withUnsafeBytes { ptr in
            AECreateDesc(DescType(typeApplicationBundleID), ptr.baseAddress, id.count, &desc)
        }
        guard created == noErr else { return .notDetermined }
        defer { AEDisposeDesc(&desc) }
        let status = AEDeterminePermissionToAutomateTarget(&desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(procNotFound): return .notRunning
        default: return .notDetermined
        }
    }

    // MARK: Requests

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refresh() } }
    }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        Self.openPane("Privacy_Accessibility")
    }

    func requestInputMonitoring() {
        if !CGRequestListenEventAccess() { Self.openPane("Privacy_ListenEvent") }
        refresh()
    }

    func requestAutomation(_ target: AutomationTarget) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.requestAutomation(target) }
            }
            return
        }
        AppleScriptRunner.shared.async {
            let s = Self.automationStatus(bundleID: target.bundleID, ask: true)
            DispatchQueue.main.async { self.automation[target.bundleID] = s }
        }
    }

    static func openPane(_ anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        NSWorkspace.shared.open(url)
    }

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
}
