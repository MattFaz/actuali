import SwiftUI

/// Transient capsule toast pinned to the top of the screen (e.g. "Posted 2
/// scheduled transactions"). Presentation/dismissal is owned by the caller;
/// pair with an `.animation` on the driving value for the slide-in/out.
struct ToastView: View {
    let text: String
    /// A trailing call to action, for a toast its caller wraps in a Button.
    var actionTitle: String?

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
            if let actionTitle {
                Text(actionTitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 4)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([text, actionTitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isStaticText)
    }
}

#Preview {
    ToastView(text: "Posted 2 scheduled transactions")
}
