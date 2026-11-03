import AppKit
import SwiftUI

/// What the HUD shows. Updated on the main thread only.
@MainActor
final class HUDModel: ObservableObject {
    enum Mode: Equatable {
        case hidden, warming, listening, speaking, thinking, executing, pending, muted, drafting
    }
    enum Flash: Equatable { case success(String), failure(String), info(String) }

    @Published var mode: Mode = .hidden
    @Published var liveText = ""
    @Published var flash: Flash?
    @Published var pendingPrompt: String?
    @Published var draftPreview: String?
    @Published var downloadProgress: Double?   // 0…1 while models download
    @Published var warning: String?           // persistent one-liner (Secure Input, Fn tap off)

    private var flashTask: Task<Void, Never>?

    func show(_ f: Flash, for seconds: Double = 2.5) {
        flash = f
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flash = nil
        }
    }
}

/// Panel that never becomes key or main, so the app you're in keeps keyboard focus.
final class HUDWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HUDPanel {
    let model = HUDModel()
    private let panel: HUDWindow

    init() {
        panel = HUDWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 120),
                          styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame = panel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    func setVisible(_ visible: Bool) {
        if visible {
            position()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func position() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 8))
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(spacing: 0) {
            if model.mode != .hidden || model.flash != nil {
                content
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: 540, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThickMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
                    .shadow(radius: 8, y: 2)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 560, height: 120, alignment: .top)
        .animation(.easeOut(duration: 0.12), value: model.mode)
    }

    @ViewBuilder var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                icon
                Text(primaryText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(model.mode == .listening && model.liveText.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            if let p = model.pendingPrompt {
                Text(p).font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange).lineLimit(2)
            }
            if let d = model.draftPreview, model.pendingPrompt == nil {
                Text("Draft (unsent): \(d)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            if let progress = model.downloadProgress {
                ProgressView(value: progress) { Text("Downloading speech models…").font(.caption) }
            }
            if let w = model.warning {
                Text(w).font(.system(size: 11)).foregroundStyle(.yellow).lineLimit(1)
            }
        }
    }

    var primaryText: String {
        if let f = model.flash {
            switch f { case .success(let s), .failure(let s), .info(let s): return s }
        }
        switch model.mode {
        case .warming: return "Warming up…"
        case .muted: return "Paused — say “resume” or use the menu bar"
        case .listening where model.liveText.isEmpty: return "Listening…"
        default: return model.liveText.isEmpty ? "Listening…" : model.liveText
        }
    }

    @ViewBuilder var icon: some View {
        if let f = model.flash {
            switch f {
            case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failure: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            case .info: Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            }
        } else {
            switch model.mode {
            case .warming: ProgressView().controlSize(.small)
            case .thinking, .executing: ProgressView().controlSize(.small)
            case .pending: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            case .muted: Image(systemName: "mic.slash.fill").foregroundStyle(.secondary)
            case .speaking: Image(systemName: "waveform").foregroundStyle(.red)
            case .drafting: Image(systemName: "text.cursor").foregroundStyle(.blue)
            default: Image(systemName: "mic.fill").foregroundStyle(.red.opacity(0.8))
            }
        }
    }
}
