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
                    SecureField("Encryption password", text: $password)
                        .textContentType(.password)
                        .disabled(isWorking)
                } header: {
                    Text("End-to-End Encrypted")
                } footer: {
                    Text("“\(budget.name)” is end-to-end encrypted. Enter its encryption password to open it on this device. This is separate from your server password.")
                }

                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.callout)
                }
            }
            .navigationTitle("Unlock Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Unlock") { Task { await unlock() } }
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
