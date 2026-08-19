// Actuali/Actuali/Views/Components/SyncStatusView.swift

import SwiftUI

struct SyncStatusView: View {
    let state: SyncState

    var body: some View {
        HStack(spacing: 4) {
            if state == .syncing {
                ProgressView()
                    .scaleEffect(0.7)
                    .transition(.scale.combined(with: .opacity))
            } else {
                // A sync that lands no new data changes nothing else on
                // screen, so the spinner giving way to a settled icon is the
                // only signal it finished. `.symbolEffect(.replace)` morphs
                // one cloud glyph into the next rather than cutting.
                Image(systemName: symbol.name)
                    .foregroundStyle(symbol.color)
                    .contentTransition(.symbolEffect(.replace))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .font(.footnote)
        .animation(AppAnimation.appearance, value: state)
    }

    /// `.syncing` never draws a symbol (the spinner stands in for it), but
    /// the switch still has to cover it.
    private var symbol: (name: String, color: Color) {
        switch state {
        case .idle, .syncing: ("checkmark.icloud", .green)
        case .offline: ("icloud.slash", .orange)
        case .error: ("exclamationmark.icloud", .red)
        }
    }
}

#Preview("Idle") {
    SyncStatusView(state: .idle)
}

#Preview("Syncing") {
    SyncStatusView(state: .syncing)
}

#Preview("Offline") {
    SyncStatusView(state: .offline)
}

#Preview("Error") {
    SyncStatusView(state: .error("Test error"))
}
