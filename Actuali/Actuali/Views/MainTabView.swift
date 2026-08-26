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

    private var overspentBadgeValue: String {
        switch overspentCount {
        case 0: ""
        case 1: "1 overspent category"
        default: "\(overspentCount) overspent categories"
        }
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular, isWideLayout {
                tabs.tabViewStyle(.sidebarAdaptable)
            } else {
                tabs
            }
        }
        .onChange(of: notificationRouter.pendingAllAccountsNavigation) { _, pending in
            if pending { selectedTab = 0 }
        }
        .onChange(of: notificationRouter.pendingAccountNavigation) { _, accountId in
            if accountId != nil { selectedTab = 0 }
        }
        .onChange(of: notificationRouter.pendingTabNavigation) { _, tab in
            if let tab {
                selectedTab = tab
                notificationRouter.pendingTabNavigation = nil
            }
        }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab(value: 1) {
                BudgetView()
            } label: {
                Label("Budget", systemImage: "wallet.bifold")
            }
            .badge(overspentCount)
            .accessibilityValue(Text(overspentBadgeValue))

            Tab(value: 0) {
                AccountsListView()
            } label: {
                Label("Accounts", systemImage: "banknote")
            }

            Tab(value: 2) {
                AddTransactionTabView()
            } label: {
                Label("Add", systemImage: "plus.circle.fill")
            }

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

struct AddTransactionTabView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @State private var showingDefaultAccountAlert = false

    var body: some View {
        let configuredId = budgetStore.defaultAccountId
        let validDefaultAccount = configuredId.flatMap { id in
            budgetStore.accounts.first { $0.id == id && !$0.closed }
        }
        let fallbackAccount = budgetStore.accounts.first { !$0.closed }

        if let account = validDefaultAccount ?? fallbackAccount {
            AddTransactionView(
                accountId: account.id,
                onSaved: {
                    Task { @MainActor in
                        await CategoryFundingAutomation.processLatestManualTransaction(using: budgetStore)
                    }
                }
            )
                .onAppear {
                    if configuredId != nil && validDefaultAccount == nil {
                        budgetStore.defaultAccountId = nil
                        showingDefaultAccountAlert = true
                    }
                }
                .alert("Default Account Unavailable", isPresented: $showingDefaultAccountAlert) {
                    Button("OK") {}
                } message: {
                    Text("Your default account is no longer available. Please configure a new default in More → Transactions & Automation.")
                }
        } else {
            ContentUnavailableView(
                "No Accounts",
                systemImage: "banknote",
                description: Text("Add an account to create transactions")
            )
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(BudgetStore.previewInstance())
}
