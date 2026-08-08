import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = initialTab()
    @StateObject private var notificationRouter = NotificationRouter.shared
    @EnvironmentObject private var budgetStore: BudgetStore

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

    /// The numeric tab badge isn't surfaced to accessibility on its own, so
    /// mirror it as a spoken value on the tab label.
    private var overspentBadgeValue: String {
        switch overspentCount {
        case 0: ""
        case 1: "1 overspent category"
        default: "\(overspentCount) overspent categories"
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            AccountsListView()
                .tabItem {
                    Label("Accounts", systemImage: "banknote")
                }
                .tag(0)

            BudgetView()
                .tabItem {
                    Label("Budget", systemImage: "wallet.bifold")
                        .accessibilityValue(overspentBadgeValue)
                }
                .badge(overspentCount)
                .tag(1)

            AddTransactionTabView(selectedTab: $selectedTab)
                .tabItem {
                    Label("Add", systemImage: "plus.circle.fill")
                }
                .tag(2)

            ReportsTabView()
                .tabItem {
                    Label("Reports", systemImage: "chart.bar.xaxis")
                }
                .tag(3)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(4)
        }
        .onChange(of: notificationRouter.pendingAllAccountsNavigation) { _, pending in
            if pending { selectedTab = 0 }
        }
    }
}

struct AddTransactionTabView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Binding var selectedTab: Int
    @State private var showingDefaultAccountAlert = false

    private var optionalTabBinding: Binding<Int?> {
        Binding<Int?>(
            get: { selectedTab },
            set: { if let newValue = $0 { selectedTab = newValue } }
        )
    }

    var body: some View {
        let configuredId = budgetStore.defaultAccountId
        let validDefaultAccount = configuredId.flatMap { id in
            budgetStore.accounts.first { $0.id == id && !$0.closed }
        }
        let fallbackAccount = budgetStore.accounts.first { !$0.closed }

        if let account = validDefaultAccount ?? fallbackAccount {
            AddTransactionView(accountId: account.id, selectedTab: optionalTabBinding)
                .onAppear {
                    if configuredId != nil && validDefaultAccount == nil {
                        budgetStore.defaultAccountId = nil
                        showingDefaultAccountAlert = true
                    }
                }
                .alert("Default Account Unavailable", isPresented: $showingDefaultAccountAlert) {
                    Button("OK") {}
                } message: {
                    Text("Your default account is no longer available. Please configure a new default in Settings.")
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
