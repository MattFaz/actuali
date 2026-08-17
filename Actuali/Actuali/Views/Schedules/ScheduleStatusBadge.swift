import SwiftUI

/// Status pill for a schedule row, mirroring the web's `StatusBadge`.
struct ScheduleStatusBadge: View {
    let status: ScheduleStatus

    var body: some View {
        Label(ScheduleDescription.statusLabel(status), systemImage: status.symbolName)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.tint.opacity(0.14), in: Capsule())
            .accessibilityLabel("Status: \(ScheduleDescription.statusLabel(status))")
    }
}

extension ScheduleStatus {
    var symbolName: String {
        switch self {
        case .missed: "exclamationmark.circle.fill"
        case .due: "exclamationmark.triangle.fill"
        case .upcoming: "calendar"
        case .paid: "checkmark.circle.fill"
        case .completed: "star.fill"
        case .scheduled: "calendar"
        }
    }

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
