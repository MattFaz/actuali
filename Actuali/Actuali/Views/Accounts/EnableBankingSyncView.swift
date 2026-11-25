import SwiftUI

/// Enable Banking runs through the user's Actual server, which holds the
/// credentials. This screen only reports whether the server is ready, sends the
/// person to their bank to approve access, and then links what the bank returns.
struct EnableBankingSyncView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    enum Readiness: Equatable {
        case checking, unavailable, notConfigured, ready
    }

    /// Upstream's list of supported countries.
    nonisolated static let countries = [
        "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IS", "IE", "IT",
        "LV", "LI", "LT", "LU", "MT", "NL", "NO", "PL", "PT", "RO", "SK", "SI", "ES", "SE", "GB",
    ]

    @State private var readiness = Readiness.checking
    @State private var redirectURL: URL?
    @State private var country = EnableBankingSyncView.defaultCountry(region: Locale.current.region?.identifier)
    @State private var banks: [EnableBankingBank] = []
    @State private var isLoadingBanks = false
    @State private var bankId: String?
    @State private var psuChoice = "personal"
    @State private var isWaiting = false
    @State private var authorizationTask: Task<Void, Never>?
    @State private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    @State private var remoteAccounts: [BankSyncRemoteAccount] = []
    @State private var errorMessage: String?
    @State private var linkTarget: BankSyncRemoteAccount?

    var body: some View {
        List {
            if !linkedAccounts.isEmpty {
                linkedSection
            }
            readinessSections
            if !remoteAccounts.isEmpty {
                remoteAccountsSection
            }
        }
        .navigationTitle("Enable Banking")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadReadiness() }
        .onDisappear { authorizationTask?.cancel() }
        .sheet(item: $linkTarget, onDismiss: {
            Task { await syncAfterLink() }
        }, content: { remote in
            BankAccountLinkView(remote: remote)
                .environmentObject(budgetStore)
        })
        .alert("Bank Sync", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Pure helpers

    nonisolated static func readiness(for status: Bool?) -> Readiness {
        guard let status else { return .unavailable }
        return status ? .ready : .notConfigured
    }

    nonisolated static func defaultCountry(region: String?) -> String {
        if let region, countries.contains(region) { return region }
        return "NL"
    }

    nonisolated static func countryName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    /// A bank that offers one usage type only gets that one; the picker is
    /// shown just when there is a real choice.
    nonisolated static func psuType(for bank: EnableBankingBank, choice: String) -> String {
        let types = bank.psuTypes ?? []
        if types.contains("personal"), types.contains("business") { return choice }
        return types.first ?? choice
    }

    /// Upstream syncs on link, so a freshly linked account has its history at
    /// once; and a re-link otherwise keeps showing the old "re-authorize" status.
    nonisolated static func accountsNeedingSync(_ accounts: [BankSyncAccount]) -> [String] {
        accounts
            .filter { $0.source == .enableBanking && !$0.closed && ($0.lastSync == nil || $0.needsAttention) }
            .map(\.id)
    }

    // MARK: - Sections

    private var linkedAccounts: [BankSyncAccount] {
        budgetStore.bankSyncAccounts.filter { $0.source == .enableBanking }
    }

    private var linkedSection: some View {
        Section {
            ForEach(linkedAccounts) { account in
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                    if let message = account.attentionMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        unlink(account)
                    } label: {
                        Text("Unlink")
                    }
                }
                .accessibilityIdentifier("enableBanking.linked.\(account.id)")
            }
            Button {
                let ids = linkedAccounts.map(\.id)
                Task { await sync(accountIds: ids) }
            } label: {
                Label("Sync Now", systemImage: "arrow.clockwise")
            }
            .disabled(budgetStore.isBankSyncing)
            .accessibilityIdentifier("enableBanking.syncNow")
        } header: {
            Text("Linked Accounts")
        }
    }

    @ViewBuilder
    private var readinessSections: some View {
        switch readiness {
        case .checking:
            Section {
                HStack {
                    ProgressView()
                    Text("Checking your server…")
                        .foregroundStyle(.secondary)
                }
            }
        case .unavailable:
            Section {
                Text("Your Actual server doesn't offer Enable Banking. Update the server to use it.")
                    .foregroundStyle(.secondary)
            }
        case .notConfigured:
            Section {
                Text("Enable Banking isn't set up on your Actual server yet. An administrator sets it up once in the Actual web app, under Bank Sync.")
                    .foregroundStyle(.secondary)
                if let redirectURL {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This redirect URL must be allowed in your Enable Banking application.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(redirectURL.absoluteString)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        case .ready:
            connectSection
        }
    }

    private var sortedCountries: [String] {
        Self.countries.sorted {
            Self.countryName($0).localizedCompare(Self.countryName($1)) == .orderedAscending
        }
    }

    private var selectedBank: EnableBankingBank? {
        banks.first { $0.id == bankId }
    }

    private var offersBothUsageTypes: Bool {
        let types = selectedBank?.psuTypes ?? []
        return types.contains("personal") && types.contains("business")
    }

    private func title(for bank: EnableBankingBank) -> String {
        bank.beta == true
            ? String(format: String(localized: "%@ (beta)"), bank.name)
            : bank.name
    }

    @ViewBuilder
    private var connectSection: some View {
        Section {
            Picker("Country", selection: $country) {
                ForEach(sortedCountries, id: \.self) { code in
                    Text(Self.countryName(code)).tag(code)
                }
            }
            .accessibilityIdentifier("enableBanking.country")
            .task(id: country) { await loadBanks() }
            .disabled(isWaiting)

            if isLoadingBanks {
                HStack {
                    ProgressView()
                    Text("Loading banks…")
                        .foregroundStyle(.secondary)
                }
            } else if banks.isEmpty {
                Text("No banks found for this country.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Bank", selection: $bankId) {
                    ForEach(banks) { bank in
                        Text(title(for: bank)).tag(Optional(bank.id))
                    }
                }
                .pickerStyle(.navigationLink)
                .disabled(isWaiting)
                .accessibilityIdentifier("enableBanking.bank")
            }

            if offersBothUsageTypes {
                Picker("Usage type", selection: $psuChoice) {
                    Text("Personal").tag("personal")
                    Text("Business").tag("business")
                }
                .disabled(isWaiting)
                .accessibilityIdentifier("enableBanking.usageType")
            }

            Button {
                authorize()
            } label: {
                Text("Authorize with Your Bank")
            }
            .disabled(selectedBank == nil || authorizationTask != nil)
            .accessibilityIdentifier("enableBanking.authorize")

            if isWaiting {
                HStack {
                    ProgressView()
                    Text("Waiting for your bank…")
                        .foregroundStyle(.secondary)
                }
                Button("Cancel", role: .cancel) {
                    authorizationTask?.cancel()
                }
                .accessibilityIdentifier("enableBanking.cancel")
            }
        } header: {
            Text("Connect a Bank")
        } footer: {
            if isWaiting {
                Text("Approve the request with your bank. If your banking app opens, come back to Actuali when it's done.")
            }
        }
    }

    private var remoteAccountsSection: some View {
        Section {
            ForEach(remoteAccounts) { remote in
                Button {
                    linkTarget = remote
                } label: {
                    BankRemoteAccountRow(remote: remote)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("enableBanking.remoteAccount.\(remote.id)")
            }
        } header: {
            Text("Accounts from Your Bank")
        } footer: {
            Text("Tap an account to link it to a budget account. Linked accounts import new transactions every time you sync.")
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

    private func loadReadiness() async {
        do {
            let status = try await budgetStore.enableBankingStatus()
            readiness = Self.readiness(for: status)
        } catch {
            errorMessage = error.localizedDescription
            readiness = .unavailable
        }
        if readiness == .notConfigured {
            redirectURL = await budgetStore.enableBankingRedirectURL()
        }
    }

    private func loadBanks() async {
        banks = []
        bankId = nil
        isLoadingBanks = true
        do {
            let loaded = try await budgetStore.enableBankingBanks(country: country)
            guard !Task.isCancelled else { return }
            banks = loaded
        } catch {
            // A newer country pick cancels this load; that isn't a failure.
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
        isLoadingBanks = false
    }

    private func unlink(_ account: BankSyncAccount) {
        Task {
            do {
                try await budgetStore.unlinkBankAccount(accountId: account.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func sync(accountIds: [String]) async {
        do {
            let result = try await budgetStore.syncBankAccounts(accountIds: accountIds)
            if !result.problems.isEmpty {
                errorMessage = result.summary
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func syncAfterLink() async {
        let ids = Self.accountsNeedingSync(budgetStore.bankSyncAccounts)
        guard !ids.isEmpty else { return }
        await sync(accountIds: ids)
    }

    private func authorize() {
        guard let bank = selectedBank else { return }
        let psuType = Self.psuType(for: bank, choice: psuChoice)
        authorizationTask = Task { await runAuthorization(bank: bank, psuType: psuType) }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func runAuthorization(bank: EnableBankingBank, psuType: String) async {
        defer {
            isWaiting = false
            authorizationTask = nil
        }
        do {
            let start = try await budgetStore.startEnableBankingAuthorization(bank: bank, psuType: psuType)
            isWaiting = true

            // The approval often happens in the banking app, and the server only
            // keeps a finished result for 30 seconds, so the open request should
            // survive a short trip away. When iOS runs out of patience the
            // assertion is released and the app suspends as usual; the wait
            // itself carries on and asks the server again on return.
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "EnableBankingAuthorization") {
                endBackgroundTask()
            }
            defer { endBackgroundTask() }

            guard let authenticator = OpenIDAuthenticator.make() else {
                throw OpenIDAuthError.noWindow
            }
            // The bank sends the browser back to the Actual server, never to this
            // app, so the sheet's own result means nothing: closing it must not
            // end the wait.
            Task { _ = try? await authenticator.open(start.url, callbackScheme: OpenIDAuthenticator.callbackScheme) }
            // Dismiss the sheet once the server reports the outcome.
            defer { authenticator.cancel() }

            remoteAccounts = try await budgetStore.awaitEnableBankingAuthorization(state: start.state)
        } catch is CancellationError {
            // Cancel button or leaving the screen.
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }
}
