import AppKit
import SwiftUI
import KeyboardShortcuts
import VoiceCommandCore

/// Small helper that shows a SwiftUI view in a regular window and keeps it alive.
@MainActor
final class WindowPresenter {
    private var windows: [String: NSWindow] = [:]

    func show<V: View>(_ id: String, title: String, size: NSSize, @ViewBuilder content: () -> V) {
        if let w = windows[id] {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = title
        w.contentViewController = NSHostingController(rootView: content())
        w.setContentSize(size)
        w.isReleasedWhenClosed = false
        w.center()
        windows[id] = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var apiKey: String = ""
    @State private var keySaved = APIKeyStore.load() != nil
    var onOpenPermissions: () -> Void

    var body: some View {
        Form {
            Section("Anthropic API key") {
                HStack {
                    SecureField(keySaved ? "Saved in Keychain — paste to replace" : "sk-ant-…", text: $apiKey)
                    Button("Save") {
                        keySaved = APIKeyStore.save(apiKey) && !apiKey.isEmpty
                        apiKey = ""
                    }.disabled(apiKey.isEmpty)
                }
                Text(keySaved ? "Key stored in the login Keychain." : "No key yet. The router needs one.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Workspace ID (only for keys not scoped to a workspace)", text: $settings.workspaceID)
                    .font(.system(.body, design: .monospaced))
            }
            Section("Hotkey") {
                Toggle("Tap Fn/🌐 to start or stop a session", isOn: $settings.fnKeyEnabled)
                HStack {
                    Text("Fallback chord (always on)")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .toggleSession)
                }
                Text("Set System Settings › Keyboard › “Press 🌐 key to” to “Do Nothing”, or macOS also opens the emoji picker or dictation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Timing") {
                Stepper("Commit delay after you stop: \(settings.commitDelayMs) ms", value: $settings.commitDelayMs, in: 250...1500, step: 50)
                Stepper("End session after \(settings.idleTimeoutSec) s of silence", value: $settings.idleTimeoutSec, in: 20...300, step: 10)
                Toggle("Thinking pauses (filler words and trailing “and”/“so” always wait)", isOn: $settings.thinkingPauses)
                Text("Drafts and pending actions suspend the silence timeout. Sessions stop after 10 minutes regardless.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Microphone") {
                Toggle("Always use the built-in microphone (keeps AirPods in high-quality mode)", isOn: $settings.useBuiltInMic)
            }
            Section("Files") {
                HStack {
                    Button("Edit app hints…") { NSWorkspace.shared.open(AppHints.fileURL) }
                    Button("Open log folder") { NSWorkspace.shared.open(CommandLog.defaultURL.deletingLastPathComponent()) }
                    Button("Permissions…", action: onOpenPermissions)
                }
                Text("Privacy: the text snapshot (apps, window and tab titles, focused field) and your transcript go to the Anthropic API. Apps in the hints file's privacyDenylist never have their titles sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 560)
    }
}

struct PermissionsView: View {
    @ObservedObject var perms: Permissions
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: perms.allGreen ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(perms.allGreen ? .green : .orange).font(.title2)
                Text(perms.allGreen ? "All set" : "VoiceCommand needs a few permissions").font(.title3).bold()
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                row("Microphone", "Hearing you", perms.microphone) { perms.requestMicrophone() }
                row("Accessibility", "Focusing windows, finding inputs, typing", perms.accessibility) { perms.requestAccessibility() }
                row("Input Monitoring", "The Fn/🌐 hotkey", perms.inputMonitoring) { perms.requestInputMonitoring() }
                row("Screen Recording", "Not needed: titles come from Accessibility", perms.screenRecording) { Permissions.openPane("Privacy_ScreenCapture") }
                row("API key", "Routing your words (Claude Haiku)", perms.apiKeySet ? .granted : .denied, button: "Settings") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                ForEach(perms.installedTargets) { t in
                    row("Automation: \(t.name)", "Tabs and terminal sessions", perms.automation[t.bundleID] ?? .notDetermined, button: "Allow") {
                        perms.requestAutomation(t)
                    }
                }
                GridRow {
                    Label("Globe key", systemImage: perms.globeKeyDoesNothing ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(perms.globeKeyDoesNothing ? .green : .secondary)
                    Text(perms.globeKeyDoesNothing ? "“Press 🌐 key to” is “Do Nothing”" : "Set “Press 🌐 key to” → “Do Nothing”")
                        .foregroundStyle(.secondary)
                    Button("Open Keyboard") { Permissions.openKeyboardSettings() }
                }
            }
            Text("After granting Accessibility or Input Monitoring, macOS may ask you to quit and reopen VoiceCommand.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 640)
        .onAppear { perms.refresh() }
        .onReceive(timer) { _ in perms.refresh() }
    }

    @ViewBuilder
    func row(_ title: String, _ why: String, _ s: Permissions.Status, button: String = "Grant", action: @escaping () -> Void) -> some View {
        GridRow {
            Label(title, systemImage: s.isGreen ? "checkmark.circle.fill" : (s == .notRunning ? "minus.circle" : "xmark.circle"))
                .foregroundStyle(s.isGreen ? .green : (s == .notRunning ? .secondary : .red))
            Text("\(why) — \(s.label)").foregroundStyle(.secondary)
            if s.isGreen { Text("") } else { Button(button, action: action) }
        }
    }
}

extension Notification.Name {
    static let openSettings = Notification.Name("VoiceCommand.openSettings")
}
