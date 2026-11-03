import SwiftUI
import VoiceCommandCore

/// Live view of the desktop snapshot exactly as the router receives it (M2).
struct DebugContextView: View {
    @ObservedObject var snapshots: SnapshotBuilder

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Desktop context (sent to the router as untrusted data)").font(.headline)
                Spacer()
                Text("built in \(snapshots.lastBuildMs) ms · \(snapshots.snapshot.takenAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Refresh") { Task { await snapshots.refresh() } }
            }
            ScrollView {
                Text(snapshots.snapshot.renderForPrompt())
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { snapshots.beginLive(poll: true) }
        .onDisappear { snapshots.endLive(poll: true) }
    }
}
