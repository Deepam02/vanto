import AppKit
import SwiftUI

/// What the HUD shows. Updated on the main thread only.
@MainActor
final class HUDModel: ObservableObject {
    enum Mode: Equatable {
        case hidden, warming, listening, speaking, thinking, executing, pending, muted, drafting, dictating
    }
    enum Flash: Equatable { case success(String), failure(String), info(String) }

    @Published var mode: Mode = .hidden
    @Published var liveText = ""
    @Published var flash: Flash?
    @Published var pendingPrompt: String?
    @Published var draftPreview: String?
    @Published var downloadProgress: Double?   // 0…1 while models download
    @Published var warning: String?           // persistent one-liner (Secure Input, Fn tap off)
    /// A larger card under the bar ("what can you do here?"), easy to scan.
    @Published var card: HelpCard?

    private var flashTask: Task<Void, Never>?
    private var cardTask: Task<Void, Never>?

    /// Show a card for a while; the next thing said hides it sooner.
    func showCard(_ c: HelpCard, for seconds: Double = 12) {
        card = c
        cardTask?.cancel()
        cardTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.card = nil
        }
    }

    func hideCard() {
        cardTask?.cancel()
        card = nil
    }

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

/// What "what can you do here?" shows: things on screen grouped by where they are, then menus
/// and examples. Names are the ones to say.
struct HelpCard: Equatable {
    struct Section: Equatable {
        var title: String
        var items: [String]
    }
    var title: String
    var subtitle: String?
    var sections: [Section]
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
        panel = HUDWindow(contentRect: NSRect(x: 0, y: 0, width: HUDView.width, height: HUDView.height),
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
    /// The panel is transparent and click-through; it's sized for the card, the bar sits on top.
    static let width: CGFloat = 680
    static let height: CGFloat = 720

    var body: some View {
        VStack(spacing: 8) {
            if model.mode != .hidden || model.flash != nil {
                content
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: 540, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThickMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
                    .shadow(radius: 8, y: 2)
            }
            if let card = model.card, model.mode != .hidden {
                HelpCardView(card: card)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Spacer(minLength: 0)
        }
        .frame(width: Self.width, height: Self.height, alignment: .top)
        .animation(.easeOut(duration: 0.12), value: model.mode)
        .animation(.easeOut(duration: 0.18), value: model.card)
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
        case .dictating where model.liveText.isEmpty: return "Dictating — release Fn, or say “send it” / “done”"
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
            case .drafting, .dictating: Image(systemName: "text.cursor").foregroundStyle(.blue)
            default: Image(systemName: "mic.fill").foregroundStyle(.red.opacity(0.8))
            }
        }
    }
}

/// The scannable card: a title, then each section's names as chips.
struct HelpCardView: View {
    let card: HelpCard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(.system(size: 16, weight: .semibold))
                if let s = card.subtitle {
                    Text(s).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            ForEach(card.sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title.uppercased())
                        .font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                    ChipFlow(spacing: 6) {
                        ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                            Text(item)
                                .font(.system(size: 12.5))
                                .lineLimit(1)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 640, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(.ultraThickMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
        .shadow(radius: 12, y: 3)
    }
}

/// Lays chips out left to right, wrapping to new lines.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? 600, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? 600, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], height: CGFloat)] {
        var rows: [(indices: [Int], height: CGFloat)] = []
        var current: [Int] = [], x: CGFloat = 0, h: CGFloat = 0
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if x + size.width > width, !current.isEmpty {
                rows.append((current, h)); current = []; x = 0; h = 0
            }
            current.append(i); x += size.width + spacing; h = max(h, size.height)
        }
        if !current.isEmpty { rows.append((current, h)) }
        return rows
    }
}

