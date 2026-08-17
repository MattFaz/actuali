import SwiftUI

/// Entry point for the Accounts tab's + button. A simple menu of account
/// creation methods, matching the PWA's own "Add account" popup — currently
/// just the local (manual) account, since bank-linked import (Plaid/
/// SimpleFin) isn't implemented here.
struct AddAccountView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    CreateLocalAccountView(onCreated: { dismiss() })
                } label: {
                    Text("Create a local account")
                }
            }
            .navigationTitle("Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// The account creation form: name, on/off-budget, and starting balance.
/// Submitting creates a real Actual account (synced via the normal CRDT
/// path, same as every other write in the app) plus, for a nonzero amount,
/// a "Starting Balance" transaction — Actual has no separate stored
/// balance field, so the transaction *is* the balance, not a shortcut.
struct CreateLocalAccountView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    /// Called on success — dismisses the whole "Add Account" sheet (both
    /// this pushed form and the popup underneath it), not just this screen,
    /// so the person lands back on the Accounts tab in one step.
    var onCreated: () -> Void = {}

    @State private var name = ""
    @State private var onBudget = true
    @State private var balanceText = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section {
                TextField("Account Name", text: $name)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
            } footer: {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Toggle("On Budget", isOn: $onBudget)
            } footer: {
                Text("Off-budget accounts (like investments or loans) aren't included in your budget's available funds.")
            }

            Section {
                HStack {
                    Text("Balance")
                    Spacer()
                    AmountInputField(
                        text: $balanceText,
                        conventionalAmountEntry: budgetStore.conventionalAmountEntry,
                        alignment: .right,
                        allowsNegative: true
                    )
                }
            } footer: {
                Text("The account's starting balance, as of today.")
            }
        }
        .navigationTitle("Create Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    Task { await create() }
                }
                .disabled(isSaving)
            }
        }
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
    }

    private func create() async {
        // A second tap can race the button's .disabled(isSaving) re-render
        // and enqueue a second Task — bail so one tap means one account.
        guard !isSaving else { return }
        guard !trimmedName.isEmpty else {
            errorMessage = "Enter an account name"
            return
        }

        let cents: Int
        let trimmedBalance = balanceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBalance.isEmpty {
            cents = 0
        } else if let dollars = AmountParser.parse(balanceText),
                  let parsedCents = Transaction.cents(fromDollars: dollars) {
            cents = parsedCents
        } else {
            errorMessage = "Invalid balance"
            return
        }

        isSaving = true
        errorMessage = nil

        do {
            try await budgetStore.createAccount(
                name: trimmedName,
                offBudget: !onBudget,
                startingBalanceCents: cents
            )
            onCreated()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}

#Preview {
    AddAccountView()
        .environmentObject(BudgetStore.previewInstance())
}
