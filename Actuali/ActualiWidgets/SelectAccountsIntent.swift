import AppIntents

struct SelectAccountsIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Select Accounts"
    static let description = IntentDescription("Choose which account balances the widget shows.")

    /// nil / empty means "not configured yet" — the widget falls back to
    /// the budget's on-budget accounts instead of rendering blank.
    @Parameter(title: "Accounts")
    var accounts: [WidgetAccountEntity]?
}
