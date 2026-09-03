import SwiftUI

struct EncryptionPasswordSheet: View {
    let budget: BudgetStore.RemoteBudget
    @ObservedObject var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var errorText: String?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(String(localized: "Encryption password"), text: $password)
                        .textContentType(.password)
                        .disabled(isWorking)
                } header: {
                    Text(String(localized: "End-to-End Encrypted"))
                } footer: {
                    Text(String(format: String(localized: "%@ is end-to-end encrypted. Enter its encryption password to open it on this device. This is separate from your server password."), budget.name))
                }

                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.callout)
                }
            }
            .navigationTitle(String(localized: "Unlock Budget"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { dismiss() }.disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Unlock")) { Task { await unlock() } }
                        .disabled(password.isEmpty || isWorking)
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
    }

    private func unlock() async {
        isWorking = true
        errorText = nil
        let failure = await budgetStore.unlockAndOpen(budget, password: password)
        isWorking = false
        if let failure {
            errorText = failure
        } else {
            dismiss()
        }
    }
}
