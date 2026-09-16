import SwiftUI

/// Capsule chip styling shared by the Budget tab's check-in strip and the
/// transaction lists' status strip, so the two strips can't drift apart.
extension View {
    func filterChip(isSelected: Bool) -> some View {
        self
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background {
                Capsule().fill(isSelected
                    ? Color.accentColor
                    : Color(.secondarySystemGroupedBackground))
            }
            .overlay {
                if !isSelected {
                    Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
            }
    }
}
