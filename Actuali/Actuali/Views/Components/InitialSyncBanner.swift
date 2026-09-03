// Actuali/Actuali/Views/Components/InitialSyncBanner.swift

import SwiftUI

/// Full-width notice pinned above a screen's content while a budget's first
/// sync is still running. Until it lands the balances on screen come from the
/// server snapshot the app downloaded, which can be hours or days behind — so
/// say so, instead of letting the user read stale figures as final (GH #126).
struct InitialSyncBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(String(localized: "Syncing — amounts may not be up to date yet"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("initialSyncBanner")
        .accessibilityLabel(String(localized: "Syncing. Amounts may not be up to date yet."))
        .accessibilityAddTraits(.updatesFrequently)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Stacks `InitialSyncBanner` above the modified view while the store's first
/// sync is in flight.
///
/// Apply this OUTSIDE a tab's `NavigationStack`, not inside it: a
/// `safeAreaInset` on the stack's content offsets the scroll view, which
/// swallows the large navigation title and leaves the toolbar buttons clipped
/// behind the banner. Stacking above the whole navigation stack shrinks its
/// frame instead, so the bar lays out normally underneath.
private struct InitialSyncBannerModifier: ViewModifier {
    @EnvironmentObject private var budgetStore: BudgetStore

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if budgetStore.isInitialSyncing {
                InitialSyncBanner()
            }
            content
        }
        .animation(AppAnimation.appearance, value: budgetStore.isInitialSyncing)
    }
}

extension View {
    func initialSyncBanner() -> some View {
        modifier(InitialSyncBannerModifier())
    }
}

#Preview {
    VStack(spacing: 0) {
        InitialSyncBanner()
        NavigationStack {
            List {
                Text("Checking")
                Text("Savings")
            }
            .navigationTitle(String(localized: "navigation.accounts"))
        }
    }
}
