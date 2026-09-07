import SwiftUI

/// Status pill for a schedule row, mirroring the web's `StatusBadge`.
struct ScheduleStatusBadge: View {
    let status: ScheduleStatus
    @Environment(\.locale) private var locale

    var body: some View {
        let statusLabel = ScheduleDescription.statusLabel(status, locale: locale)

        return Text(statusLabel)
            .font(.caption.weight(.medium))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.tint.opacity(0.14), in: Capsule())
            .accessibilityLabel(ReportStrings.format("Status: %@", statusLabel, locale: locale))
    }
}

extension ScheduleStatus {
    var tint: Color {
        switch self {
        case .missed: .red
        case .due: .orange
        case .upcoming: .blue
        case .paid: .green
        case .completed: .secondary
        case .scheduled: .secondary
        }
    }
}
