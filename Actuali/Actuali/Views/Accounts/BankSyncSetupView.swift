import SwiftUI

private let simpleFINBridgeURL = URL(string: "https://bridge.simplefin.org/")!

/// Set up SimpleFIN on this device and wire its accounts to budget accounts.
///
/// Two states: before a setup token is claimed it's a paste field, after it's
/// the list of accounts the bridge serves, each either linked to a budget
/// account or waiting to be.
struct BankSyncSetupView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    @State private var setupToken = ""
    @State private var isConnecting = false
    @State private var isLoadingAccounts = false
    @State private var remoteAccounts: [SimpleFINAccount] = []
    /// Problems the bridge reported alongside the accounts — a connection that
    /// needs re-authenticating, most often.
    @State private var bridgeErrors: [String] = []
    @State private var errorMessage: String?
    @State private var linkTarget: SimpleFINAccount?
    @State private var showingDisconnectConfirmation = false

    var body: some View {
        List {
            if budgetStore.isSimpleFINConfigured {
                connectedSections
            } else {
                setupSection
            }
        }
        .navigationTitle("Bank Sync")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if budgetStore.isSimpleFINConfigured, remoteAccounts.isEmpty {
                await loadRemoteAccounts()
            }
        }
        .sheet(item: $linkTarget) { remote in
            BankAccountLinkView(remote: remote)
                .environmentObject(budgetStore)
        }
        .alert("Bank Sync", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Disconnect SimpleFIN?",
            isPresented: $showingDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) { disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your accounts stay linked and keep the transactions they've already imported. To sync from this device again you'll need a new setup token.")
        }
    }

    // MARK: - Not connected yet

    @ViewBuilder
    private var setupSection: some View {
        Section {
            TextField("Setup token", text: $setupToken, axis: .vertical)
                .lineLimit(3...6)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.footnote, design: .monospaced))
                .disabled(isConnecting)

            Button {
                connect()
            } label: {
                if isConnecting {
                    HStack {
                        ProgressView()
                        Text("Connecting…")
                    }
                } else {
                    Text("Connect")
                }
            }
            .disabled(isConnecting || setupToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("SimpleFIN")
        } footer: {
            Text("SimpleFIN gives apps read-only access to your bank. Create a token at bridge.simplefin.org and paste it here — it can only be claimed once, so use a fresh one if another app already has it.")
        }

        Section {
            Link(destination: simpleFINBridgeURL) {
                Label("Open SimpleFIN Bridge", systemImage: "safari")
            }
        }
    }

    // MARK: - Connected

    @ViewBuilder
    private var connectedSections: some View {
        if !bridgeErrors.isEmpty {
            Section {
                ForEach(bridgeErrors, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Needs attention")
            }
        }

        Section {
            if isLoadingAccounts {
                HStack {
                    ProgressView()
                    Text("Loading accounts…")
                        .foregroundStyle(.secondary)
                }
            } else if remoteAccounts.isEmpty {
                Text("No accounts yet. Add a bank at SimpleFIN, then pull to refresh.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(remoteAccounts) { remote in
                    Button {
                        linkTarget = remote
                    } label: {
                        remoteAccountRow(remote)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Bank Accounts")
        } footer: {
            Text("Tap an account to link it to a budget account. Linked accounts import new transactions every time you sync.")
        }

        Section {
            Button {
                Task { await loadRemoteAccounts() }
            } label: {
                Label("Refresh account list", systemImage: "arrow.clockwise")
            }
            .disabled(isLoadingAccounts)

            Button(role: .destructive) {
                showingDisconnectConfirmation = true
            } label: {
                Label("Disconnect SimpleFIN", systemImage: "minus.circle")
            }
        }
    }

    private func remoteAccountRow(_ remote: SimpleFINAccount) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(remote.name)
                Text(remote.org.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let linked = linkedAccountName(for: remote) {
                    Label(linked, systemImage: "link")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
            if let cents = remote.balanceCents {
                Text(budgetStore.displayBalance(cents))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    /// The budget account a bridge account is already wired to, if any.
    private func linkedAccountName(for remote: SimpleFINAccount) -> String? {
        guard let link = budgetStore.bankSyncAccounts.first(where: {
            $0.externalAccountId == remote.id && $0.source == .simpleFin
        }) else { return nil }
        return link.name
    }

    // MARK: - Actions

    private var errorAlertBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func connect() {
        let token = setupToken
        isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                try await budgetStore.connectSimpleFIN(setupToken: token)
                setupToken = ""
                await loadRemoteAccounts()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadRemoteAccounts() async {
        isLoadingAccounts = true
        defer { isLoadingAccounts = false }
        do {
            let set = try await budgetStore.fetchSimpleFINAccounts()
            remoteAccounts = set.accounts
            bridgeErrors = set.errors
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func disconnect() {
        do {
            try budgetStore.disconnectSimpleFIN()
            remoteAccounts = []
            bridgeErrors = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Pick what a bridge account feeds: an account the budget already has, or a
/// new one created for it.
struct BankAccountLinkView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    let remote: SimpleFINAccount

    @State private var newAccountOffBudget = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let linked = currentLink {
                    Section {
                        Button(role: .destructive) {
                            perform { try await budgetStore.unlinkBankAccount(accountId: linked.id) }
                        } label: {
                            Label("Unlink from \(linked.name)", systemImage: "link.badge.plus")
                        }
                    } footer: {
                        Text("Transactions already imported stay in the account.")
                    }
                }

                Section {
                    Toggle("Off budget", isOn: $newAccountOffBudget)
                    Button {
                        createAndLink()
                    } label: {
                        Label("Create “\(remote.name)”", systemImage: "plus.circle")
                    }
                } header: {
                    Text("New account")
                } footer: {
                    Text("Creates a budget account for \(remote.name) at \(remote.org.displayName) and links it. Its opening balance is worked out on the first sync.")
                }

                Section("Link to an existing account") {
                    if linkableAccounts.isEmpty {
                        Text("Every open account is already linked.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(linkableAccounts) { account in
                            Button {
                                perform {
                                    try await budgetStore.linkBankAccount(
                                        accountId: account.id, to: remote
                                    )
                                }
                            } label: {
                                HStack {
                                    Text(account.name)
                                    Spacer()
                                    Text(budgetStore.displayBalance(account.balance))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .disabled(isWorking)
            .navigationTitle(remote.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Bank Sync", isPresented: errorAlertBinding) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var currentLink: BankSyncAccount? {
        budgetStore.bankSyncAccounts.first {
            $0.externalAccountId == remote.id && $0.source == .simpleFin
        }
    }

    /// Open accounts with no bank feed of their own. An account already linked
    /// to a different bridge account isn't offered — one feed per account.
    private var linkableAccounts: [Account] {
        let linkedIds = Set(budgetStore.bankSyncAccounts.map(\.id))
        return budgetStore.accounts.filter { !$0.closed && !linkedIds.contains($0.id) }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func createAndLink() {
        perform {
            let account = try await budgetStore.createAccount(
                name: remote.name,
                offBudget: newAccountOffBudget,
                // No opening balance here: the first sync works it out from
                // the bridge's current balance and the history it downloads.
                startingBalanceCents: 0
            )
            try await budgetStore.linkBankAccount(accountId: account.id, to: remote)
        }
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await work()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
