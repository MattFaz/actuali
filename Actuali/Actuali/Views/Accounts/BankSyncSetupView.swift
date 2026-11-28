import SwiftUI

private let simpleFINBridgeURL = URL(string: "https://bridge.simplefin.org/")!

/// Bank Sync hub: pick a provider, and set how far back linked accounts
/// import. The date lives here rather than inside either provider screen so
/// it stays reachable whether or not a provider is connected or available.
struct BankSyncSetupView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    @State private var errorMessage: String?
    @State private var importStartDate = Date()
    /// Nil until the stored day is loaded, which is what keeps the picker's
    /// initial assignment from being written back (or from kicking a sync).
    @State private var savedImportStartDay: Int?
    @State private var isBackfilling = false

    var body: some View {
        List {
            Section {
                if Self.showsWalletRow(for: budgetStore.appleWalletAvailability) {
                    NavigationLink {
                        AppleWalletSyncView()
                    } label: {
                        Label("Apple Wallet", systemImage: "wallet.pass")
                    }
                    .accessibilityIdentifier("bankSync.provider.appleWallet")
                }
                NavigationLink {
                    SimpleFINSyncView()
                } label: {
                    Label("SimpleFIN", systemImage: "building.columns")
                }
                .accessibilityIdentifier("bankSync.provider.simpleFIN")
                NavigationLink {
                    EnableBankingSyncView()
                } label: {
                    Label("Enable Banking", systemImage: "building.columns.fill")
                }
                .accessibilityIdentifier("bankSync.provider.enableBanking")
            }
            Section {
                Toggle(String(localized: "Approve Before Importing"), isOn: $budgetStore.stagesBankImports)
                    .accessibilityIdentifier("bankSync.stageImports")
            } footer: {
                Text(String(localized: "New transactions from a bank sync wait in Review until you approve them. Matches to transactions you already have still apply right away."))
            }
            importStartSection
        }
        .navigationTitle("Bank Sync")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Starts out .unsupported, so ask before deciding whether Wallet
            // can be offered here at all.
            await budgetStore.refreshAppleWalletAvailability()
            let day = await budgetStore.resolvedBankSyncImportStartDay()
            importStartDate = Transaction.date(fromYYYYMMDD: day)
            savedImportStartDay = day
        }
        .alert("Bank Sync", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Wallet row state

    enum WalletRow: Equatable {
        case accounts, connect, openSettings
    }

    /// Backing out of Apple's consent sheet reports `.denied`, and FinanceKit
    /// never shows it again — only Settings can grant access from there, so
    /// the denied row has to lead to it (GH #555).
    nonisolated static func walletRow(for availability: AppleWalletAvailability) -> WalletRow {
        switch availability {
        case .authorized: .accounts
        case .denied: .openSettings
        case .notDetermined, .unsupported: .connect
        }
    }

    /// Wallet data is iPhone-only and currently US-only, so the provider row
    /// only exists where FinanceKit can actually serve it.
    nonisolated static func showsWalletRow(for availability: AppleWalletAvailability) -> Bool {
        availability != .unsupported
    }

    // MARK: - Import start

    private var importStartSection: some View {
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
            Text("Linked accounts import transactions from this day on. It starts out as the day this budget began. For Apple Wallet accounts, pick an earlier day to pull in older history. Transactions already imported always stay.")
        }
    }

    /// Store the day, then reach it. The window is derived from the day, so a
    /// run that fails here costs nothing — the next sync reaches just as far.
    /// This is only what makes the import visible while the screen is open.
    private func applyImportStart(_ day: Int) async {
        budgetStore.setBankSyncImportStartDay(day)
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

    private var errorAlertBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: {
            if !$0 {
                errorMessage = nil
            }
        })
    }
}

// MARK: - Apple Wallet

/// Apple Wallet (FinanceKit): connect once, then its accounts are ready to
/// link.
struct AppleWalletSyncView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var walletAccounts: [AppleWalletAccount] = []
    @State private var isConnectingWallet = false
    @State private var isLoadingWalletAccounts = false
    @State private var errorMessage: String?
    @State private var linkTarget: BankSyncRemoteAccount?

    var body: some View {
        List {
            walletSection
        }
        .navigationTitle("Apple Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshWallet() }
        // Wallet access is granted in Settings, outside the app, and .task
        // doesn't re-run on return — without this the denied row stays stale.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshWallet() }
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
    }

    private var walletSection: some View {
        Section {
            switch BankSyncSetupView.walletRow(for: budgetStore.appleWalletAvailability) {
            case .accounts:
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
                            BankRemoteAccountRow(remote: account.remoteAccount)
                        }
                        .buttonStyle(.plain)
                    }
                }
            case .openSettings:
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Settings to Allow Wallet Access", systemImage: "gear")
                }
                .accessibilityIdentifier("bankSync.wallet.openSettings")
            case .connect:
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
            switch BankSyncSetupView.walletRow(for: budgetStore.appleWalletAvailability) {
            case .accounts:
                Text("Tap an account to link it. Apple Card, Apple Cash and Savings transactions import automatically when you open the app or pull to refresh — read from this device's Wallet and stored in your budget file like any other transaction.")
            case .openSettings:
                Text("Allow Actuali to read Wallet data in Settings to sync Apple Card, Apple Cash and Savings.")
            case .connect:
                Text("Link Apple Card, Apple Cash and Savings so their transactions and balances import automatically when you sync. Apple asks once which data Actuali may read.")
            }
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: {
            if !$0 {
                errorMessage = nil
            }
        })
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

    private func refreshWallet() async {
        await budgetStore.refreshAppleWalletAvailability()
        if budgetStore.appleWalletAvailability == .authorized {
            await loadWalletAccounts()
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
}

// MARK: - SimpleFIN

/// SimpleFIN has two states — with a connection available (the server's own,
/// or one claimed on this device) it lists the accounts the bridge serves;
/// with neither, it's a paste field for a setup token. Which connection is in
/// play is worth saying out loud: only the server's is shared with the web app.
struct SimpleFINSyncView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    @State private var setupToken = ""
    @State private var isConnecting = false
    @State private var isLoadingAccounts = false
    @State private var remoteAccounts: [SimpleFINAccount] = []
    @State private var errorMessage: String?
    @State private var linkTarget: BankSyncRemoteAccount?
    @State private var showingDisconnectConfirmation = false

    var body: some View {
        List {
            if budgetStore.canSyncBanks {
                connectedSections
            } else {
                setupSection
            }
        }
        .navigationTitle("SimpleFIN")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Which half of the screen applies depends on whether the server
            // does SimpleFIN itself, so ask before deciding.
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
                        BankRemoteAccountRow(remote: remote.remoteAccount)
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

    // MARK: - Actions

    private var errorAlertBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: {
            if !$0 {
                errorMessage = nil
            }
        })
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

    private func disconnect() {
        do {
            try budgetStore.disconnectSimpleFIN()
            remoteAccounts = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Shared

/// One provider-side account in a provider screen's list: what it is, and
/// whether it imports into a budget account yet. The open ones carry the
/// action and the tint and the settled ones stay quiet, so the eye lands on
/// what is left to do.
struct BankRemoteAccountRow: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    let remote: BankSyncRemoteAccount
    /// Off where the screen already names the one bank every row belongs to.
    var showsInstitution = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(remote.name)
                    if showsInstitution {
                        Text(remote.institutionName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let cents = remote.balanceCents {
                    Text(budgetStore.displayBalance(cents))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            HStack {
                if let linked = remote.link(in: budgetStore.bankSyncAccounts) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                        Text("Imports into \(linked.name)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Not imported")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    // Drawn as a button though the whole row takes the tap: a
                    // bare state word reads as nothing to do.
                    Text("Set Up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
            }
        }
        // The row sits in a plain button, which only takes taps on what is
        // drawn; without this the gaps between its parts are dead.
        .contentShape(Rectangle())
    }
}

/// The two ways to give a bank account a budget account, as one question with
/// a screen behind each answer, so nobody reads a form and a list at once to
/// find theirs. A section for any list inside a navigation stack.
struct BankAccountLinkChoices: View {
    let remote: BankSyncRemoteAccount
    var footer: String?
    /// Called with the budget account's id once a link succeeded and the
    /// screen that made it has closed.
    let onLinked: (String) -> Void

    var body: some View {
        Section {
            NavigationLink {
                BankAccountLinkStep(step: .existing, remote: remote, onLinked: onLinked)
            } label: {
                Label("An account already in my budget", systemImage: "link")
            }
            .accessibilityIdentifier("bankLink.existing")
            NavigationLink {
                BankAccountLinkStep(step: .new, remote: remote, onLinked: onLinked)
            } label: {
                Label("A new account", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("bankLink.new")
        } header: {
            Text("Where should transactions from \(remote.name) go?")
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }
}

/// One answer's screen: the budget accounts to pick from, or the form for a
/// new one.
private struct BankAccountLinkStep: View {
    enum Step {
        case existing, new
    }

    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    let step: Step
    let remote: BankSyncRemoteAccount
    let onLinked: (String) -> Void

    @State private var newAccountOffBudget = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            switch step {
            case .existing: existingAccounts
            case .new: newAccount
            }
        }
        .disabled(isWorking)
        .navigationTitle(step == .existing ? Text("Existing account") : Text("New account"))
        .navigationBarTitleDisplayMode(.inline)
        .alert("Bank Sync", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var newAccount: some View {
        Section {
            Toggle("Off budget", isOn: $newAccountOffBudget)
            Button {
                link {
                    try await budgetStore.createAccount(
                        name: remote.name,
                        offBudget: newAccountOffBudget,
                        // No opening balance here: the first sync works it out from
                        // the bridge's current balance and the history it downloads.
                        startingBalanceCents: 0
                    ).id
                }
            } label: {
                Label(String(format: String(localized: "Create “%@”"), remote.name), systemImage: "plus.circle")
            }
        } footer: {
            Text(String(format: String(localized: "Creates a budget account for %@ at %@ and links it. Its opening balance is worked out on the first sync."), remote.name, remote.institutionName))
        }
    }

    private var existingAccounts: some View {
        Section {
            if linkableAccounts.isEmpty {
                Text("Every open account is already linked.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(linkableAccounts) { account in
                    Button {
                        link { account.id }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name)
                                if replaceableIds.contains(account.id) {
                                    Text("Already linked. Linking here replaces that link.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(budgetStore.displayBalance(account.balance))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        // A plain button only takes taps on what is drawn.
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } footer: {
            // Only where it applies: on a first connection nothing here was
            // linked before.
            if linkableAccounts.contains(where: { replaceableIds.contains($0.id) }) {
                Text("After re-authorizing your bank, choose the account that was linked before to replace its old link.")
            }
        }
    }

    private var replaceableIds: Set<String> {
        BankAccountLinkView.enableBankingLinkedIds(budgetStore.bankSyncAccounts)
    }

    private var linkableAccounts: [Account] {
        BankAccountLinkView.linkableAccounts(
            accounts: budgetStore.accounts,
            linked: budgetStore.bankSyncAccounts,
            remoteSource: remote.source
        )
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: {
            if !$0 {
                errorMessage = nil
            }
        })
    }

    /// Links the budget account `account` yields, then closes this screen
    /// before reporting: whoever listens may take the row that led here off
    /// its list.
    private func link(_ account: @escaping @MainActor () async throws -> String) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let accountId = try await account()
                try await budgetStore.linkBankAccount(accountId: accountId, to: remote)
                dismiss()
                onLinked(accountId)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// The sheet a provider screen opens for one of its accounts: where its
/// transactions go and, once it is linked, a way to stop them.
struct BankAccountLinkView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    let remote: BankSyncRemoteAccount
    /// Called with the budget account's id once a link succeeded, just before
    /// the sheet closes. Unlinking doesn't call it.
    var onLinked: ((String) -> Void)?

    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                BankAccountLinkChoices(remote: remote) { accountId in
                    onLinked?(accountId)
                    dismiss()
                }

                if let linked = remote.link(in: budgetStore.bankSyncAccounts) {
                    Section {
                        Button(role: .destructive) {
                            unlink(linked)
                        } label: {
                            Label(String(format: String(localized: "Unlink from %@"), linked.name), systemImage: "link.badge.plus")
                        }
                    } footer: {
                        Text("Transactions already imported stay in the account.")
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

    /// The budget accounts fed through Enable Banking.
    nonisolated static func enableBankingLinkedIds(_ linked: [BankSyncAccount]) -> Set<String> {
        Set(linked.filter { $0.source == .enableBanking }.map(\.id))
    }

    /// Open accounts with no bank feed of their own. An account already linked
    /// to a different bridge account isn't offered — one feed per account.
    /// Enable Banking is the exception: re-authorizing issues new account ids,
    /// so an account linked through it must stay replaceable. The ones whose
    /// link has gone stale come first; the healthy ones come last, so one tap
    /// on a free account never lands on a working link.
    nonisolated static func linkableAccounts(
        accounts: [Account],
        linked: [BankSyncAccount],
        remoteSource: BankSyncSource
    ) -> [Account] {
        let linkedIds = Set(linked.map(\.id))
        let open = accounts.filter { !$0.closed && !linkedIds.contains($0.id) }
        guard remoteSource == .enableBanking else { return open }
        let replaceableIds = enableBankingLinkedIds(linked)
        let attentionIds = Set(linked.filter { $0.source == .enableBanking && $0.needsAttention }.map(\.id))
        let replaceableOpen = accounts.filter { !$0.closed && replaceableIds.contains($0.id) }
        return replaceableOpen.filter { attentionIds.contains($0.id) }
            + open
            + replaceableOpen.filter { !attentionIds.contains($0.id) }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: {
            if !$0 {
                errorMessage = nil
            }
        })
    }

    private func unlink(_ linked: BankSyncAccount) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await budgetStore.unlinkBankAccount(accountId: linked.id)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
