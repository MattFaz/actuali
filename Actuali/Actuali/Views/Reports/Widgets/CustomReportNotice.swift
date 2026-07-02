import SwiftUI

/// Banner shown at the top of the Reports dashboard when the user has one or
/// more widgets of types we don't render yet.
struct UnsupportedTypesNotice: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("Limited reports are currently available, more will be available soon.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    UnsupportedTypesNotice()
        .padding()
}
