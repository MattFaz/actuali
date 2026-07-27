import AppIntents

struct ActualiShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogTransactionIntent(),
            phrases: [
                "Log transaction in \(.applicationName)",
                "Add transaction to \(.applicationName)",
                "Log a transaction in \(.applicationName)",
            ],
            shortTitle: "Log Transaction",
            systemImageName: "dollarsign.circle"
        )

        AppShortcut(
            intent: GetAccountBalanceIntent(),
            phrases: [
                "Check account balance in \(.applicationName)",
                "Get account balance in \(.applicationName)",
                "Check \(.applicationName) account balance",
            ],
            shortTitle: "Account Balance",
            systemImageName: "building.columns"
        )

        AppShortcut(
            intent: GetCategoryBalanceIntent(),
            phrases: [
                "Check category balance in \(.applicationName)",
                "Get category balance in \(.applicationName)",
                "How much is left in \(.applicationName)",
            ],
            shortTitle: "Category Balance",
            systemImageName: "chart.pie"
        )

        AppShortcut(
            intent: GetCategoriesIntent(),
            phrases: [
                "Get categories in \(.applicationName)",
                "List categories in \(.applicationName)",
            ],
            shortTitle: "List Categories",
            systemImageName: "folder"
        )

        AppShortcut(
            intent: GetPayeesIntent(),
            phrases: [
                "Get payees in \(.applicationName)",
                "List payees in \(.applicationName)",
            ],
            shortTitle: "List Payees",
            systemImageName: "person.2"
        )

        AppShortcut(
            intent: GetAccountsIntent(),
            phrases: [
                "Get accounts in \(.applicationName)",
                "List accounts in \(.applicationName)",
            ],
            shortTitle: "List Accounts",
            systemImageName: "creditcard"
        )
    }
}
