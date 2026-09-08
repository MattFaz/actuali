import AppIntents

struct ActualiShortcutsProvider: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            // Voice invocation is the one surface where the spoken confirmation is
            // wanted; see LogTransactionIntent.showConfirmation.
            intent: LogTransactionIntent(showConfirmation: true),
            phrases: [
                "Log transaction in \(.applicationName)",
                "Log transaction to \(\.$account) in \(.applicationName)",
                "Add transaction to \(.applicationName)",
                "Log a transaction in \(.applicationName)",
            ],
            shortTitle: "Log Transaction",
            systemImageName: "plus"
        )

        AppShortcut(
            intent: AddTransactionWithReviewIntent(),
            phrases: [
                "Add transaction with review in \(.applicationName)",
                "Enter transaction in \(.applicationName)",
                "Review a transaction in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Add with Review"),
            systemImageName: "square.and.pencil"
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
            shortTitle: LocalizedStringResource("Account Balance"),
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
            shortTitle: LocalizedStringResource("Category Balance"),
            systemImageName: "chart.pie.fill"
        )

        AppShortcut(
            intent: GetCategoriesIntent(),
            phrases: [
                "Get categories in \(.applicationName)",
                "List categories in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("List Categories"),
            systemImageName: "folder.fill"
        )

        AppShortcut(
            intent: GetPayeesIntent(),
            phrases: [
                "Get payees in \(.applicationName)",
                "List payees in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("List Payees"),
            systemImageName: "person.2.fill"
        )

        AppShortcut(
            intent: GetAccountsIntent(),
            phrases: [
                "Get accounts in \(.applicationName)",
                "List accounts in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("List Accounts"),
            systemImageName: "creditcard.fill"
        )

        AppShortcut(
            intent: ParseAndQueueTransactionIntent(),
            phrases: [
                "Import transaction from text in \(.applicationName)",
                "Parse transaction in \(.applicationName)",
                "Queue transaction in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Import from Text"),
            systemImageName: "tray.and.arrow.down"
        )
    }
}
