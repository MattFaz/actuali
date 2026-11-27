import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = initialTab()
    @StateObject private var notificationRouter = NotificationRouter.shared
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isWideLayout) private var isWideLayout

    private static func initialTab() -> Int {
        #if DEBUG
        if let idx = CommandLine.arguments.firstIndex(of: "-initialTab"),
           idx + 1 < CommandLine.arguments.count,
           let tab = Int(CommandLine.arguments[idx + 1]) {
            return tab
        }
        #endif
        return StartTab.persisted.tabTag
    }

    private var overspentCount: Int {
        budgetStore.overspentBadgeCount
    }

    nonisolated static func overspentBadgeValue(
        count: Int,
        locale: Locale = .current,
        bundle: Bundle = .main
    ) -> String {
        guard count > 0 else { return "" }
        return ReportStrings.localized("\(count) overspent categories", locale: locale, bundle: bundle)
    }

    var body: some View {
        Group {
            // A wide iPad window (never iPhone) offers the sidebar as an
            // alternative to the floating tab bar. Gated on width, not just on
            // regular size class: in an 11-inch portrait window the sidebar
            // has no room to sit beside the content, so the toggle only ever
            // swaps the tab bar for a drawer over the top of it. Narrower
            // windows — and every phone — keep the plain tab bar.
            if horizontalSizeClass == .regular, isWideLayout {
                tabs.tabViewStyle(.sidebarAdaptable)
            } else {
                tabs
            }
        }
        .onChange(of: notificationRouter.pendingAllAccountsNavigation) { _, pending in
            if pending {
                selectedTab = 0
            }
        }
        // A credit card reminder tap routes to a transaction list, which
        // lives on the Accounts tab.
        .onChange(of: notificationRouter.pendingAccountNavigation) { _, accountId in
            if accountId != nil {
                selectedTab = 0
            }
        }
        // initial: true covers a widget link that arrives on a cold launch,
        // before this view exists.
        .onChange(of: notificationRouter.pendingTabNavigation, initial: true) { _, tab in
            if let tab {
                selectedTab = tab
                notificationRouter.pendingTabNavigation = nil
            }
        }
        // One sheet for every way in: the floating add button, the Home Screen
        // quick action and the widget link. It lives here rather than on a
        // page so it opens from any tab, and with the button switched off.
        .sheet(isPresented: $notificationRouter.pendingAddTransaction) {
            AddTransactionSheet()
        }
        #if DEBUG
        // Lets UI tests start with the form open.
        .onAppear {
            if CommandLine.arguments.contains("-presentAddTransaction") {
                notificationRouter.pendingAddTransaction = true
            }
        }
        #endif
    }

    /// The `Tab` value API rather than `tabItem`: `sidebarAdaptable` above only
    /// takes effect for tabs declared this way. Renders identically to the
    /// `tabItem` form in compact width.
    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab(value: 1) {
                BudgetView()
            } label: {
                Label("Budget", systemImage: "wallet.bifold")
            }
            .badge(overspentCount)
            // On the tab, not its label: under the Tab API the tab's own
            // modifiers are what reach the tab bar item. XCUITest cannot read
            // it, but VoiceOver has no other source for the count.
            .accessibilityValue(Text(Self.overspentBadgeValue(count: overspentCount)))

            Tab(value: 0) {
                AccountsListView()
            } label: {
                Label("Accounts", systemImage: "building.columns")
            }

            // Tag 2 was the Add tab. The others keep their numbers, which the
            // `-initialTab` launch argument and StartTab.tabTag rely on.
            Tab(value: 3) {
                ReportsTabView()
            } label: {
                Label("Reports", systemImage: "chart.bar.xaxis")
            }

            Tab(value: 4) {
                SettingsView()
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }
}

/// The add-transaction form for the default account, else the first open one.
struct AddTransactionSheet: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @State private var showingDefaultAccountAlert = false

    private func handleManualTransactionSaved(_ savedTransactionId: String?) {
        CategoryFundingAutomation.processIfNeeded(savedTransactionId, using: budgetStore)
    }

    var body: some View {
        let configuredId = budgetStore.defaultAccountId
        let validDefaultAccount = configuredId.flatMap { id in
            budgetStore.accounts.first { $0.id == id && !$0.closed }
        }
        let fallbackAccount = budgetStore.accounts.first { !$0.closed }

        if let account = validDefaultAccount ?? fallbackAccount {
            AddTransactionView(
                accountId: account.id,
                onSaved: handleManualTransactionSaved
            )
            .onAppear {
                if configuredId != nil, validDefaultAccount == nil {
                    budgetStore.defaultAccountId = nil
                    showingDefaultAccountAlert = true
                }
            }
            .alert(String(localized: "Default Account Unavailable"), isPresented: $showingDefaultAccountAlert) {
                Button(String(localized: "OK")) {}
            } message: {
                Text(String(localized: "Your default account is no longer available. Please configure a new default in More → Transactions & Automation."))
            }
        } else {
            ContentUnavailableView(
                "No Accounts",
                systemImage: "building.columns",
                description: Text("Add an account to create transactions")
            )
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(BudgetStore.previewInstance())
}
