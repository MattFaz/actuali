import SwiftUI

extension View {
    /// Floats the round "+" over the bottom-right corner (just above the tab
    /// bar inside a tab) and leaves scroll content room to clear it. Apply it
    /// to a navigation stack's root content, so pushed screens don't show it.
    func floatingAddButton() -> some View {
        modifier(FloatingAddButtonModifier())
    }
}

private struct FloatingAddButtonModifier: ViewModifier {
    @EnvironmentObject private var budgetStore: BudgetStore

    func body(content: Content) -> some View {
        // Both parts keep `content` in place when the setting flips, so the
        // page underneath isn't rebuilt. The room under the scroll content is
        // safe area padding, not `contentMargins`: a scroll view that sets its
        // own bottom margin (Budget's cards do) would replace an outer one.
        content
            .safeAreaPadding(.bottom, budgetStore.showsAddButton ? FloatingAddButton.clearance : 0)
            .overlay(alignment: .bottomTrailing) {
                if budgetStore.showsAddButton {
                    FloatingAddButton()
                        .padding(FloatingAddButton.margin)
                        // A search keyboard covers the button rather than
                        // pushing it up over the results.
                        .ignoresSafeArea(.keyboard)
                }
            }
    }
}

private struct FloatingAddButton: View {
    static let diameter: CGFloat = 56
    static let margin: CGFloat = 16
    /// What the button takes from the bottom of a page: itself and the margin
    /// on both sides, so the last row can scroll clear of it.
    static let clearance = diameter + 2 * margin

    var body: some View {
        Button {
            NotificationRouter.shared.pendingAddTransaction = true
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: Self.diameter, height: Self.diameter)
                .contentShape(Circle())
        }
        .modifier(FloatingAddBackground())
        .keyboardShortcut("n", modifiers: .command)
        .accessibilityLabel("Add Transaction")
        .accessibilityIdentifier("floatingAdd.button")
    }
}

/// Liquid Glass on iOS 26 and a material with a shadow before that.
private struct FloatingAddBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        }
    }
}
