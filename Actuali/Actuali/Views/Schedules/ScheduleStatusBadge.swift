import SwiftUI

/// Status pill for a schedule row, mirroring the web's `StatusBadge`.
struct ScheduleStatusBadge: View {
    let status: ScheduleStatus

    var body: some View {
        Text(ScheduleDescription.statusLabel(status))
            .font(.caption.weight(.medium))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.tint.opacity(0.14), in: Capsule())
            .accessibilityLabel(String(format: String(localized: "Status: %@"), ScheduleDescription.statusLabel(status)))
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
