// Actuali/Actuali/Views/Components/AppAnimation.swift

import SwiftUI

/// The app's animation vocabulary. Three curves, each tied to one kind of
/// change, so a section collapsing in the budget table and a section
/// collapsing in the accounts list read as the same gesture rather than two
/// screens that happen to both move.
enum AppAnimation {
    /// Expanding or collapsing a section. Short on purpose: the rows it
    /// reveals are the point, not the motion getting there.
    static let disclosure = Animation.easeInOut(duration: 0.2)

    /// A figure changing under the user — a budget edit, a transfer, a sync
    /// landing new transactions. Snappy so the new number is readable
    /// immediately; the roll only has to say *which* number moved.
    static let amount = Animation.snappy(duration: 0.28)

    /// Something appearing or disappearing in place: a banner, a status
    /// icon, a toast.
    static let appearance = Animation.easeInOut(duration: 0.25)
}

extension View {
    /// Rolls a currency figure to its new value instead of swapping it, so a
    /// budget edit or a landed sync is visible *where* it landed rather than
    /// only in a total the user has to go looking for.
    ///
    /// Takes the displayed string rather than the cents behind it, so masked
    /// balances cross-fade on the same curve when "Hide Balances" flips.
    func animatedAmount(_ value: String) -> some View {
        contentTransition(.numericText())
            .animation(AppAnimation.amount, value: value)
    }
}

/// The rotating chevron every collapsible section header uses. One symbol
/// turned rather than two symbols swapped: a rotation shows the header
/// *doing* something, where `chevron.right` → `chevron.down` is a jump cut.
///
/// Carries its own animation so a caller that toggles state outside a
/// `withAnimation` still gets the turn.
struct DisclosureChevron: View {
    let isExpanded: Bool
    var font: Font = .caption

    var body: some View {
        Image(systemName: "chevron.right")
            .font(font)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(AppAnimation.disclosure, value: isExpanded)
    }
}

#Preview("Chevron") {
    VStack(spacing: 24) {
        DisclosureChevron(isExpanded: false)
        DisclosureChevron(isExpanded: true)
    }
}
