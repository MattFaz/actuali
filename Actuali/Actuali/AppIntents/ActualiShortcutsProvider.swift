import AppIntents

struct ActualiShortcutsProvider: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogTransactionIntent(),
            phrases: [
                "Log transaction in \(.applicationName)",
                "Log transaction to \(\.$account) in \(.applicationName)",
                "Add transaction to \(.applicationName)",
                "Log a transaction in \(.applicationName)",
            ],
            shortTitle: "Log Transaction",
            systemImageName: "plus.circle.fill"
        )

        AppShortcut(
            intent: GetAccountBalanceIntent(),
            phrases: [
                "Check \(\.$account) balance in \(.applicationName)",
                "Get \(\.$account) balance in \(.applicationName)",
                "Check account balance in \(.applicationName)",
                "Get account balance in \(.applicationName)",
                "Check \(.applicationName) account balance",
            ],
            shortTitle: "Account Balance",
            systemImageName: "building.columns.fill"
        )

        AppShortcut(
            intent: GetCategoryBalanceIntent(),
            phrases: [
                "How much is left in \(\.$category) in \(.applicationName)",
                "Check \(\.$category) balance in \(.applicationName)",
                "Get \(\.$category) balance in \(.applicationName)",
                "Check category balance in \(.applicationName)",
            ],
            shortTitle: "Category Balance",
            systemImageName: "chart.pie.fill"
        )

        AppShortcut(
            intent: GetCategoriesIntent(),
            phrases: [
                "Get categories in \(.applicationName)",
                "List categories in \(.applicationName)",
            ],
            shortTitle: "List Categories",
            systemImageName: "folder.fill"
        )

        AppShortcut(
            intent: GetPayeesIntent(),
            phrases: [
                "Get payees in \(.applicationName)",
                "List payees in \(.applicationName)",
            ],
            shortTitle: "List Payees",
            systemImageName: "person.2.fill"
        )

        AppShortcut(
            intent: GetAccountsIntent(),
            phrases: [
                "Get accounts in \(.applicationName)",
                "List accounts in \(.applicationName)",
            ],
            shortTitle: "List Accounts",
            systemImageName: "creditcard.fill"
        )
    }
}
