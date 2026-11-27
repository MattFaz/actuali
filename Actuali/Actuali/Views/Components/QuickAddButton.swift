import SwiftUI

extension View {
    /// Floats the round "+" over the bottom-right corner (just above the tab
    /// bar inside a tab) and leaves scroll content room to clear it. Apply it
    /// to a navigation stack's root content, so pushed screens don't show it.
    func quickAddButton() -> some View {
        modifier(QuickAddButtonModifier())
    }
}

private struct QuickAddButtonModifier: ViewModifier {
    @EnvironmentObject private var budgetStore: BudgetStore

    /// Off by choice, or nothing to add to: without an open account the form
    /// has no account to open on.
    private var isShown: Bool {
        budgetStore.showsQuickAddButton && budgetStore.accounts.contains { !$0.closed }
    }

    func body(content: Content) -> some View {
        // Both parts keep `content` in place when the button comes or goes, so
        // the page underneath isn't rebuilt. The room under the scroll content
        // is safe area padding, not `contentMargins`: a scroll view that sets
        // its own bottom margin (Budget's cards do) would replace an outer one.
        content
            .safeAreaPadding(.bottom, isShown ? QuickAddButton.clearance : 0)
            .overlay(alignment: .bottomTrailing) {
                if isShown {
                    QuickAddButton()
                        .padding(QuickAddButton.margin)
                        // A search keyboard covers the button rather than
                        // pushing it up over the results.
                        .ignoresSafeArea(.keyboard)
                }
            }
    }
}

private struct QuickAddButton: View {
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
        .modifier(QuickAddBackground())
        .accessibilityLabel("Add Transaction")
        .accessibilityIdentifier("quickAdd.button")
    }
}

/// Liquid Glass on iOS 26 and a material with a shadow before that.
private struct QuickAddBackground: ViewModifier {
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
