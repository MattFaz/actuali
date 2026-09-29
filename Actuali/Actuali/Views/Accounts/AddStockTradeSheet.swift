import SwiftUI

/// Sheet for recording a stock buy or sell trade as a native Actual Budget transaction.
struct AddStockTradeSheet: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    let accountId: String

    @State private var isBuy = true
    @State private var symbol = ""
    @State private var companyName = ""
    @State private var sharesText = ""
    @State private var priceText = ""
    @State private var tradeDate = Date()
    @State private var isSearching = false
    @State private var isSaving = false
    @State private var searchResults: [StockSearchResult] = []
    @State private var searchTask: Task<Void, Never>?
    /// Set to true while programmatically assigning `symbol` to prevent the
    /// onChange handler from re-triggering a search after result selection.
    @State private var suppressNextSearch = false

    private var shares: Double? {
        // AmountParser handles locale decimal separators (comma vs period).
        AmountParser.parse(sharesText)
    }

    private var pricePerShare: Double? {
        AmountParser.parse(priceText)
    }

    private var totalAmount: Double? {
        guard let s = shares, let p = pricePerShare, s > 0, p > 0 else { return nil }
        return s * p
    }

    private var isValid: Bool {
        !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (shares ?? 0) > 0 &&
            (pricePerShare ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "Trade Type"), selection: $isBuy) {
                        Text(String(localized: "Buy")).tag(true)
                        Text(String(localized: "Sell")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("stockTrade.typePicker")
                }

                Section(String(localized: "Stock / Asset")) {
                    HStack {
                        TextField(String(localized: "Ticker Symbol (e.g. AAPL)"), text: $symbol)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("stockTrade.symbolField")
                            .onChange(of: symbol) { _, newValue in
                                if suppressNextSearch {
                                    suppressNextSearch = false
                                    return
                                }
                                debounceSearch(newValue)
                            }

                        if isSearching {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    if !searchResults.isEmpty {
                        ForEach(searchResults) { result in
                            Button {
                                selectSearchResult(result)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.symbol)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.primary)
                                        if let name = result.name {
                                            Text(name)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if let ex = result.exchange {
                                        Text(ex)
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.secondary.opacity(0.15))
                                            .clipShape(Capsule())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("stockTrade.result.\(result.symbol)")
                        }
                    }

                    if !companyName.isEmpty {
                        HStack {
                            Text(String(localized: "Name"))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(companyName)
                        }
                        .font(.subheadline)
                    }
                }

                Section(String(localized: "Trade Details")) {
                    HStack {
                        Text(String(localized: "Quantity (Shares)"))
                        Spacer()
                        TextField("0", text: $sharesText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("stockTrade.sharesField")
                    }

                    HStack {
                        Text(String(localized: "Price per Share"))
                        Spacer()
                        TextField("0.00", text: $priceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("stockTrade.priceField")
                    }

                    DatePicker(
                        String(localized: "Date"),
                        selection: $tradeDate,
                        displayedComponents: .date
                    )
                    .accessibilityIdentifier("stockTrade.datePicker")

                    if let totalAmount {
                        HStack {
                            Text(String(localized: "Total Amount"))
                                .fontWeight(.semibold)
                            Spacer()
                            let totalCents = Transaction.cents(fromDollars: totalAmount) ?? 0
                            Text(budgetStore.formatCurrency(totalCents))
                                .fontWeight(.bold)
                                .foregroundStyle(isBuy ? Color.primary : Color.green)
                        }
                    }
                }
            }
            .navigationTitle(isBuy ? String(localized: "Buy Stock") : String(localized: "Sell Stock"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("stockTrade.cancel")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        Task { await saveTrade() }
                    }
                    .disabled(!isValid || isSaving)
                    .accessibilityIdentifier("stockTrade.save")
                }
            }
        }
    }

    private func debounceSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            guard !Task.isCancelled else { return }
            let results = await budgetStore.yahooFinanceClient.search(query: trimmed)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.searchResults = results
                self.isSearching = false
            }
        }
    }

    private func selectSearchResult(_ result: StockSearchResult) {
        searchTask?.cancel()
        searchResults = []
        suppressNextSearch = true
        symbol = result.symbol
        companyName = result.name ?? ""

        // Try prefilling price from live quote
        Task {
            if let quote = await budgetStore.yahooFinanceClient.quote(for: result.symbol) {
                await MainActor.run {
                    if priceText.isEmpty {
                        priceText = String(format: "%.2f", quote.price)
                    }
                }
            }
        }
    }

    private func saveTrade() async {
        guard let s = shares, let p = pricePerShare else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            try await budgetStore.recordStockTrade(
                accountId: accountId,
                symbol: symbol,
                name: companyName.isEmpty ? nil : companyName,
                shares: s,
                pricePerShare: p,
                date: tradeDate,
                isBuy: isBuy
            )
            // Refresh quotes for the newly added symbol
            await budgetStore.refreshEquityQuotes(for: accountId, forceRefresh: true)
            dismiss()
        } catch {
            budgetStore.error = error.localizedDescription
        }
    }
}
