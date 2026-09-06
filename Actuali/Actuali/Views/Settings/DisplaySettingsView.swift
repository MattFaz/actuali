import SwiftUI

private struct CurrencyOption: Identifiable, Sendable {
    let symbol: String
    let code: String
    var id: String { code }
}

/// Every currency in Actual's loot-core currencies list, plus a few
/// user-requested extras Actual lacks (AMD, BDT, NOK, NZD, ZAR). Sorted by
/// code. Display-only — all budget math is currency-agnostic integer
/// cents, and rendering uses the system formatter for the ISO code.
private let currencyOptions = [
    CurrencyOption(symbol: "د.إ", code: "AED"),
    CurrencyOption(symbol: "֏", code: "AMD"),
    CurrencyOption(symbol: "Arg$", code: "ARS"),
    CurrencyOption(symbol: "A$", code: "AUD"),
    CurrencyOption(symbol: "৳", code: "BDT"),
    CurrencyOption(symbol: "R$", code: "BRL"),
    CurrencyOption(symbol: "Br", code: "BYN"),
    CurrencyOption(symbol: "C$", code: "CAD"),
    CurrencyOption(symbol: "Fr", code: "CHF"),
    CurrencyOption(symbol: "CLP$", code: "CLP"),
    CurrencyOption(symbol: "CN¥", code: "CNY"),
    CurrencyOption(symbol: "Col$", code: "COP"),
    CurrencyOption(symbol: "₡", code: "CRC"),
    CurrencyOption(symbol: "Kč", code: "CZK"),
    CurrencyOption(symbol: "kr", code: "DKK"),
    CurrencyOption(symbol: "RD$", code: "DOP"),
    CurrencyOption(symbol: "ج.م", code: "EGP"),
    CurrencyOption(symbol: "€", code: "EUR"),
    CurrencyOption(symbol: "£", code: "GBP"),
    CurrencyOption(symbol: "Q", code: "GTQ"),
    CurrencyOption(symbol: "HK$", code: "HKD"),
    CurrencyOption(symbol: "Ft", code: "HUF"),
    CurrencyOption(symbol: "Rp", code: "IDR"),
    CurrencyOption(symbol: "₪", code: "ILS"),
    CurrencyOption(symbol: "₹", code: "INR"),
    CurrencyOption(symbol: "﷼", code: "IRR"),
    CurrencyOption(symbol: "J$", code: "JMD"),
    CurrencyOption(symbol: "¥", code: "JPY"),
    CurrencyOption(symbol: "₩", code: "KRW"),
    CurrencyOption(symbol: "Rs.", code: "LKR"),
    CurrencyOption(symbol: "L", code: "MDL"),
    CurrencyOption(symbol: "ден", code: "MKD"),
    CurrencyOption(symbol: "MX$", code: "MXN"),
    CurrencyOption(symbol: "RM", code: "MYR"),
    CurrencyOption(symbol: "kr", code: "NOK"),
    CurrencyOption(symbol: "NZ$", code: "NZD"),
    CurrencyOption(symbol: "S/", code: "PEN"),
    CurrencyOption(symbol: "₱", code: "PHP"),
    CurrencyOption(symbol: "Rs.", code: "PKR"),
    CurrencyOption(symbol: "zł", code: "PLN"),
    CurrencyOption(symbol: "ر.ق", code: "QAR"),
    CurrencyOption(symbol: "lei", code: "RON"),
    CurrencyOption(symbol: "дин", code: "RSD"),
    CurrencyOption(symbol: "₽", code: "RUB"),
    CurrencyOption(symbol: "ر.س", code: "SAR"),
    CurrencyOption(symbol: "kr", code: "SEK"),
    CurrencyOption(symbol: "S$", code: "SGD"),
    CurrencyOption(symbol: "฿", code: "THB"),
    CurrencyOption(symbol: "₺", code: "TRY"),
    CurrencyOption(symbol: "NT$", code: "TWD"),
    CurrencyOption(symbol: "₴", code: "UAH"),
    CurrencyOption(symbol: "$", code: "USD"),
    CurrencyOption(symbol: "$U", code: "UYU"),
    CurrencyOption(symbol: "UZS", code: "UZS"),
    CurrencyOption(symbol: "R", code: "ZAR")
]

struct DisplaySettingsView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @State private var dashboardPages: [DashboardPage] = []

    /// Routes the picker's selection through `setCurrencyCode`, which
    /// persists the choice into the budget's own `preferences` table (not
    /// just UserDefaults) so it survives a relaunch (GH #59).
    private var currencySelection: Binding<String> {
        Binding(
            get: { budgetStore.currencyCode },
            set: { newValue in
                Task { await budgetStore.setCurrencyCode(newValue) }
            }
        )
    }

    private var numberFormatSelection: Binding<ActualNumberFormat> {
        Binding(
            get: { budgetStore.numberFormat },
            set: { newValue in
                Task { await budgetStore.setNumberFormat(newValue) }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Currency", selection: currencySelection) {
                    // Empty code = no currency, matching Actual's
                    // defaultCurrencyCode convention. Amounts render as
                    // plain numbers.
                    Text("None").tag("")
                    ForEach(currencyOptions) { option in
                        Text("\(option.symbol) \(option.code)").tag(option.code)
                    }
                }

                Picker("Number Formatting", selection: numberFormatSelection) {
                    ForEach(ActualNumberFormat.allCases) { format in
                        Text(format.example).tag(format)
                    }
                }

                // Meaningless with no currency selected, so hidden there.
                if !budgetStore.currencyCode.isEmpty {
                    Toggle("Symbol Only", isOn: $budgetStore.useNarrowCurrencySymbol)
                }
            } header: {
                Text("Amount Formatting")
            } footer: {
                if !budgetStore.currencyCode.isEmpty {
                    Text("Symbol Only shows amounts with just the currency symbol — $ instead of NZ$.")
                }
            }

            Section("Appearance") {
                Picker("Appearance", selection: $budgetStore.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }

            Section {
                Picker("Start Page", selection: $budgetStore.startTab) {
                    ForEach(StartTab.allCases) { tab in
                        Text(tab.label).tag(tab)
                    }
                }

                // Nothing to choose between with one page, and the picker
                // would only ever offer the page already on screen.
                if dashboardPages.count > 1 {
                    Picker("Default Dashboard", selection: $budgetStore.defaultDashboardPageId) {
                        Text("First Dashboard").tag(nil as String?)
                        ForEach(dashboardPages) { page in
                            Text(page.name.isEmpty ? "Untitled" : page.name)
                                .tag(page.id as String?)
                        }
                    }
                }
            } header: {
                Text("App Navigation")
            } footer: {
                Text("Start Page takes effect the next time the app opens.")
            }
        }
        .readableWidth()
        .navigationTitle("Display")
        .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.horizontal, 6, for: .scrollContent)
        .task {
            await reloadDashboardPages()
        }
    }

    private func reloadDashboardPages() async {
        guard let database = budgetStore.databaseForLogger else {
            dashboardPages = []
            return
        }
        // Bail on a failed or cancelled read rather than treating "no pages"
        // as fact: a budget switch cancels this task mid-read and resumes
        // after currentBudgetId has already flipped, so clearing the default
        // here would wipe the *incoming* budget's preference.
        guard let pages = try? await database.fetchDashboardPages() else { return }
        dashboardPages = pages
        // A default naming a page that's since been deleted has no tag to
        // match in the picker, and the Reports tab already falls back to the
        // first page — so drop it rather than show a phantom selection.
        if let id = budgetStore.defaultDashboardPageId,
           !pages.contains(where: { $0.id == id }) {
            budgetStore.defaultDashboardPageId = nil
        }
    }
}
