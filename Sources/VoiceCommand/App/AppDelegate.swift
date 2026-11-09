import AppKit
import KeyboardShortcuts
import VoiceCommandCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let windows = WindowPresenter()
    private let permissions = Permissions()
    private let fnMonitor = FnKeyMonitor()
    private let hud = HUDPanel()
    private let speech = SpeechEngine()
    private let log = CommandLog()
    private lazy var hints = AppHints.loadOrInstall()
    private lazy var snapshots = SnapshotBuilder(hints: hints)
    private lazy var executor = Executor(hints: hints, snapshots: snapshots)
    private lazy var client = ClaudeClient(apiKey: APIKeyStore.load())
    private lazy var session = SessionController(speech: speech, snapshots: snapshots, executor: executor,
                                                 client: client, hud: hud, log: log)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon(.idle)
        session.onStateChange = { [weak self] s in self?.updateIcon(s) }

        // M4 harness: run a scripted list of actions, write a report, quit.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--action-script"), i + 1 < args.count {
            runActionScript(args[i + 1])
            return
        }
        // Debug: write an app's accessibility tree to a file, to see why a text box or button
        // isn't found. Usage: open -n VoiceCommand.app --args --dump-ax "Claude" /tmp/claude-ax.txt
        if let i = args.firstIndex(of: "--dump-ax"), i + 2 < args.count {
            Task { await AXDump.write(app: args[i + 1], to: args[i + 2]); NSApp.terminate(nil) }
            return
        }
        // Debug: transcribe audio files through the speech pipeline and print the segments.
        if let i = args.firstIndex(of: "--transcribe-file"), i + 1 < args.count {
            transcribeFiles(Array(args[(i + 1)...]))
            return
        }

        KeyboardShortcuts.onKeyUp(for: .toggleSession) { [weak self] in self?.session.toggle() }
        fnMonitor.onTap = { [weak self] in
            guard let self, AppSettings.shared.fnKeyEnabled else { return }
            self.session.toggle()
        }
        fnMonitor.onHoldStart = { [weak self] in
            guard let self, AppSettings.shared.fnKeyEnabled else { return }
            self.session.startDictation()
        }
        fnMonitor.onHoldEnd = { [weak self] in
            Task { await self?.session.finishDictation() }
        }
        fnMonitor.onHealthChange = { [weak self] ok in
            self?.hud.model.warning = ok ? nil : "Fn key stopped working — use ⌃⌥Space"
        }
        startFnMonitor()

        NotificationCenter.default.addObserver(forName: .openSettings, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showSettings() }
        }

        permissions.refresh()
        // First launch: show onboarding until everything is green.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.permissions.refresh()
            if !self.permissions.allGreen || !UserDefaults.standard.bool(forKey: "onboarded") { self.showPermissions() }
            UserDefaults.standard.set(true, forKey: "onboarded")
        }
        // First launch shows a progress bar while models download in the background.
        if !UserDefaults.standard.bool(forKey: "modelsDownloaded") {
            hud.setVisible(true)
            hud.model.mode = .warming
            Task {
                do {
                    try await speech.loadModels { [weak self] p in
                        MainActor.assumeIsolated { self?.hud.model.downloadProgress = p < 1 ? p : nil }
                    }
                    UserDefaults.standard.set(true, forKey: "modelsDownloaded")
                    hud.model.show(.success("Speech models ready — tap Fn to start"), for: 3)
                } catch {
                    hud.model.show(.failure("Model download failed: \(error.localizedDescription)"), for: 5)
                }
                hud.model.downloadProgress = nil
                try? await Task.sleep(nanoseconds: 3_200_000_000)
                if !session.isActive { hud.model.mode = .hidden; hud.setVisible(false) }
            }
        }
    }

    private func transcribeFiles(_ paths: [String]) {
        func out(_ s: String) { FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!) }
        speech.onEvent = { e in
            switch e {
            case .speechStarted: out("  [speech start]")
            case .partial: break
            case .segment(let text, let live, _, let start, let end, let ms):
                out(String(format: "  segment %.2fs: \"%@\" (live: \"%@\", TDT %d ms)", end.timeIntervalSince(start), text, live, ms))
            case .failure(let m): out("  failure: \(m)")
            }
        }
        Task {
            do {
                let t0 = Date()
                try await speech.loadModels { _ in }
                await speech.setVocabulary(extra: [])
                out(String(format: "models loaded in %.1fs", Date().timeIntervalSince(t0)))
                for p in paths {
                    out("== \(p)")
                    let t = Date()
                    try await speech.simulate(file: URL(fileURLWithPath: p))
                    try? await Task.sleep(nanoseconds: 200_000_000)   // let main-queue events print
                    out(String(format: "  (%.2fs wall)", Date().timeIntervalSince(t)))
                }
            } catch {
                out("error: \(error)")
            }
            exit(0)
        }
    }

    private func runActionScript(_ path: String) {
        hud.setVisible(true)
        hud.model.mode = .executing
        hud.model.liveText = "Running action script…"
        Task {
            guard AXIsProcessTrusted() else {
                hud.model.show(.failure("Grant Accessibility to VoiceCommand first"), for: 4)
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                NSApp.terminate(nil)
                return
            }
            let runner = ActionScriptRunner(snapshots: snapshots, executor: executor)
            let r = await runner.run(path: path)
            hud.model.show(r.passed == r.total ? .success("Action script: \(r.passed)/\(r.total) passed")
                                                : .failure("Action script: \(r.passed)/\(r.total) passed — see report"), for: 4)
            NSWorkspace.shared.open(r.reportURL)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            NSApp.terminate(nil)
        }
    }

    private func startFnMonitor() {
        if !fnMonitor.start() {
            // Input Monitoring not granted yet; retry quietly until it is.
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] t in
                Task { @MainActor in
                    guard let self else { t.invalidate(); return }
                    if CGPreflightListenEventAccess(), self.fnMonitor.start() { t.invalidate() }
                }
            }
        }
    }

    private func updateIcon(_ state: SessionController.State) {
        let symbol: String
        switch state {
        case .idle: symbol = "mic"
        case .muted: symbol = "mic.slash"
        case .warming: symbol = "hourglass"
        case .pending: symbol = "hand.raised"
        default: symbol = "mic.fill"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "VoiceCommand")
        statusItem.button?.contentTintColor = state == .idle || state == .muted ? nil : .systemRed
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let active = session.isActive
        menu.addItem(item(active ? "Stop Session" : "Start Session", #selector(toggleSession)))
        if active {
            menu.addItem(item(session.isMuted ? "Resume Listening" : "Pause Listening", #selector(toggleMute)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Show Context…", #selector(showContext)))
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(item("Permissions…", #selector(showPermissions)))
        menu.addItem(item("Open Log Folder", #selector(openLogs)))
        menu.addItem(.separator())
        menu.addItem(item("Quit VoiceCommand", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleSession() { session.toggle() }
    @objc private func toggleMute() { session.setMuted(!session.isMuted) }
    @objc private func openLogs() { NSWorkspace.shared.open(CommandLog.defaultURL.deletingLastPathComponent()) }
    @objc private func quit() {
        session.end(reason: "quit")
        log.flush()
        NSApp.terminate(nil)
    }

    @objc func showSettings() {
        windows.show("settings", title: "VoiceCommand Settings", size: NSSize(width: 560, height: 620)) {
            SettingsView(onOpenPermissions: { [weak self] in self?.showPermissions() })
        }
    }

    @objc func showPermissions() {
        permissions.refresh()
        windows.show("permissions", title: "VoiceCommand Permissions", size: NSSize(width: 680, height: 460)) {
            PermissionsView(perms: permissions)
        }
    }

    @objc func showContext() {
        windows.show("context", title: "VoiceCommand Context", size: NSSize(width: 760, height: 540)) {
            DebugContextView(snapshots: snapshots)
        }
    }
}
