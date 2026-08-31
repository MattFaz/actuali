import SwiftUI

private let simpleFINBridgeURL = URL(string: "https://bridge.simplefin.org/")!

/// Set up bank feeds and wire their accounts to budget accounts.
///
/// Two providers. Apple Wallet (FinanceKit) shows on devices that have Wallet
/// data at all: connect once and its accounts are ready to link. SimpleFIN has
/// two states — with a connection available (the server's own, or one claimed
/// on this device) it lists the accounts the bridge serves; with neither, it's
/// a paste field for a setup token. Which SimpleFIN connection is in play is
/// worth saying out loud: only the server's is shared with the web app.
struct BankSyncSetupView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    @State private var setupToken = ""
    @State private var isConnecting = false
    @State private var isLoadingAccounts = false
    @State private var remoteAccounts: [SimpleFINAccount] = []
    @State private var walletAccounts: [AppleWalletAccount] = []
    @State private var isConnectingWallet = false
    @State private var isLoadingWalletAccounts = false
    @State private var errorMessage: String?
    @State private var linkTarget: BankSyncRemoteAccount?
    @State private var showingDisconnectConfirmation = false
    @State private var importStartDate = Date()
    /// Nil until the stored day is loaded, which is what keeps the picker's
    /// initial assignment from being written back (or from kicking a sync).
    @State private var savedImportStartDay: Int?
    @State private var isBackfilling = false

    var body: some View {
        List {
            if budgetStore.appleWalletAvailability != .unsupported {
                walletSection
            }
            if budgetStore.canSyncBanks {
                connectedSections
            } else {
                setupSection
            }
            importStartSection
        }
        .navigationTitle("Bank Sync")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let day = await budgetStore.resolvedBankSyncImportStartDay()
            importStartDate = Transaction.date(fromYYYYMMDD: day)
            savedImportStartDay = day
            await budgetStore.refreshAppleWalletAvailability()
            if budgetStore.appleWalletAvailability == .authorized {
                await loadWalletAccounts()
            }
            // Which half of the SimpleFIN screen applies depends on whether
            // the server does SimpleFIN itself, so ask before deciding.
            await budgetStore.refreshBankSyncSource()
            if budgetStore.canSyncBanks, remoteAccounts.isEmpty {
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

    // MARK: - Apple Wallet

    @ViewBuilder
    private var walletSection: some View {
        Section {
            switch budgetStore.appleWalletAvailability {
            case .authorized:
                if isLoadingWalletAccounts {
                    HStack {
                        ProgressView()
                        Text("Loading accounts…")
                            .foregroundStyle(.secondary)
                    }
                } else if walletAccounts.isEmpty {
                    Text("No Wallet accounts found on this device.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(walletAccounts) { account in
                        Button {
                            linkTarget = account.remoteAccount
                        } label: {
                            remoteAccountRow(account.remoteAccount)
                        }
                        .buttonStyle(.plain)
                    }
                }
            case .denied:
                Label("Wallet access is turned off", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            default:
                Button {
                    connectWallet()
                } label: {
                    if isConnectingWallet {
                        HStack {
                            ProgressView()
                            Text("Connecting…")
                        }
                    } else {
                        Label("Connect Apple Wallet", systemImage: "wallet.pass")
                    }
                }
                .disabled(isConnectingWallet)
            }
        } header: {
            Text("Apple Wallet")
        } footer: {
            switch budgetStore.appleWalletAvailability {
            case .authorized:
                Text("Tap an account to link it. Apple Card, Apple Cash and Savings transactions import automatically when you open the app or pull to refresh — read from this device's Wallet and stored in your budget file like any other transaction.")
            case .denied:
                Text("Allow Actuali to read Wallet data in Settings to sync Apple Card, Apple Cash and Savings.")
            default:
                Text("Link Apple Card, Apple Cash and Savings so their transactions and balances import automatically when you sync. Apple asks once which data Actuali may read.")
            }
        }
    }

    // MARK: - Import start

    @ViewBuilder
    private var importStartSection: some View {
        // Nothing to import from means nothing to date, so the calendar only
        // shows where one of the two providers is actually on offer.
        if budgetStore.canSyncBanks || budgetStore.appleWalletAvailability != .unsupported {
            Section {
                DatePicker(
                    "Import transactions since",
                    selection: $importStartDate,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .disabled(savedImportStartDay == nil || isBackfilling)
                .onChange(of: importStartDate) { _, newDate in
                    let day = Transaction.yyyymmdd(from: newDate)
                    guard let saved = savedImportStartDay, day != saved else { return }
                    savedImportStartDay = day
                    Task { await applyImportStart(day) }
                }

                if isBackfilling {
                    HStack {
                        ProgressView()
                        Text("Importing older transactions…")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Import Start Date")
            } footer: {
                Text("Linked accounts import transactions from this day on. It starts out as the day this budget began; pick an earlier day to pull in older history. Transactions already imported always stay.")
            }
        }
    }

    /// Store the day, then reach it. The store holds the day as a debt until a
    /// sync honours it, so a run that fails here is retried by the next one —
    /// this is only what makes the import visible while the screen is open.
    private func applyImportStart(_ day: Int) async {
        await budgetStore.setBankSyncImportStartDay(day)
        isBackfilling = true
        defer { isBackfilling = false }
        do {
            // The throwing entry point, not `runBankSync`: its summary alert
            // lives on the accounts tab, which this screen may not be inside.
            let result = try await budgetStore.syncBankAccounts()
            if !result.problems.isEmpty {
                errorMessage = result.problems.joined(separator: "\n\n")
            }
        } catch {
            errorMessage = error.localizedDescription
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
            Text("SimpleFIN gives apps read-only access to your bank. Create a token at bridge.simplefin.org and paste it here — it can only be claimed once, so use a fresh one if another app already has it.\n\nIf you set SimpleFIN up on your Actual server instead, this app uses that connection automatically and you won't need a token here at all.")
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
        Section {
            Label(
                budgetStore.serverProvidesBankSync
                    ? "Using your server's SimpleFIN connection"
                    : "Using this device's SimpleFIN connection",
                systemImage: budgetStore.serverProvidesBankSync ? "server.rack" : "iphone"
            )
            .foregroundStyle(.secondary)
        } footer: {
            if budgetStore.serverProvidesBankSync {
                Text("Your Actual server holds the SimpleFIN credentials, so this app and the web app share one connection — accounts you link in either place work in both.")
            } else {
                Text("Your server has no SimpleFIN connection of its own, so this device uses the token you gave it. Accounts you link here still appear in the web app, but it needs its own SimpleFIN setup to sync them.")
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
                        linkTarget = remote.remoteAccount
                    } label: {
                        remoteAccountRow(remote.remoteAccount)
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

            if budgetStore.isSimpleFINConfigured {
                Button(role: .destructive) {
                    showingDisconnectConfirmation = true
                } label: {
                    Label("Disconnect this device", systemImage: "minus.circle")
                }
            }
        }
    }

    private func remoteAccountRow(_ remote: BankSyncRemoteAccount) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(remote.name)
                Text(remote.institutionName)
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

    /// The budget account a provider-side account is already wired to, if any.
    private func linkedAccountName(for remote: BankSyncRemoteAccount) -> String? {
        guard let link = budgetStore.bankSyncAccounts.first(where: {
            $0.externalAccountId == remote.id && $0.syncSource == remote.source.rawValue
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
            remoteAccounts = try await budgetStore.fetchBankAccounts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func connectWallet() {
        isConnectingWallet = true
        Task {
            defer { isConnectingWallet = false }
            do {
                // A declined consent sheet needs no alert of its own — the
                // section flips to its denied state, which says what to do.
                if try await budgetStore.connectAppleWallet() {
                    await loadWalletAccounts()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadWalletAccounts() async {
        isLoadingWalletAccounts = true
        defer { isLoadingWalletAccounts = false }
        do {
            walletAccounts = try await budgetStore.fetchAppleWalletAccounts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func disconnect() {
        do {
            try budgetStore.disconnectSimpleFIN()
            remoteAccounts = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Pick what a provider-side account feeds: an account the budget already
/// has, or a new one created for it.
struct BankAccountLinkView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    let remote: BankSyncRemoteAccount

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
                    Text("Creates a budget account for \(remote.name) at \(remote.institutionName) and links it. Its opening balance is worked out on the first sync.")
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
            $0.externalAccountId == remote.id && $0.syncSource == remote.source.rawValue
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
