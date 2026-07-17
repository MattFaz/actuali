import SwiftUI

/// Transient capsule toast pinned to the top of the screen (e.g. "Posted 2
/// scheduled transactions"). Presentation/dismissal is owned by the caller;
/// pair with an `.animation` on the driving value for the slide-in/out.
struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isStaticText)
    }
}

#Preview {
    ToastView(text: "Posted 2 scheduled transactions")
}
