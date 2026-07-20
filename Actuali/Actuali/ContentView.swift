//
//  ContentView.swift
//  Actuali
//
//  Created by Matt Farrell on 9/12/2025.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @StateObject private var notificationRouter = NotificationRouter.shared

    /// Presents whenever the store publishes an error; dismissing clears it
    /// so the next failure can present again.
    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { budgetStore.error != nil },
            set: { if !$0 { budgetStore.error = nil } }
        )
    }

    var body: some View {
        MainTabView()
            .alert("Something Went Wrong", isPresented: errorAlertBinding) {
                Button("OK") {}
            } message: {
                Text(budgetStore.error ?? "")
            }
            .sheet(item: $notificationRouter.pendingPrefill) { prefill in
                if let accountId = resolvedAccountId(for: prefill) {
                    AddTransactionView(
                        accountId: accountId,
                        payee: prefill.payee,
                        amountCents: prefill.amountCents,
                        date: prefill.date
                    )
                } else {
                    ContentUnavailableView(
                        "No Accounts",
                        systemImage: "banknote",
                        description: Text("Add an account to create transactions")
                    )
                }
            }
            .sheet(item: $notificationRouter.destination) { destination in
                switch destination {
                case .editor(let transaction):
                    AddTransactionView(editing: transaction)
                        .environmentObject(budgetStore)
                case .uncategorized:
                    NavigationStack {
                        UncategorizedTransactionsView()
                    }
                    .environmentObject(budgetStore)
                }
            }
    }

    /// The notification's account if it is still open, else the default
    /// account, else any open account (mirrors `AddTransactionTabView`).
    private func resolvedAccountId(for prefill: TransactionPrefill) -> String? {
        let openAccounts = budgetStore.accounts.filter { !$0.closed }
        if let id = prefill.accountId, openAccounts.contains(where: { $0.id == id }) { return id }
        if let id = budgetStore.defaultAccountId, openAccounts.contains(where: { $0.id == id }) { return id }
        return openAccounts.first?.id
    }
}

#Preview {
    ContentView()
        .environmentObject(BudgetStore.previewInstance())
}
