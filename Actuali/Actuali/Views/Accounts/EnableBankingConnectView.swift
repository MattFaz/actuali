import SwiftUI

/// One bank authorization: pick the bank, send the person to it to approve
/// access, then link the accounts it returns. The Actual server holds the
/// Enable Banking credentials, so this only carries the request through.
struct EnableBankingConnectView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    /// Authorizing a linked account's bank again starts with that bank chosen.
    let preferredBankName: String?

    /// Upstream's list of supported countries.
    nonisolated static let countries = [
        "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IS", "IE", "IT",
        "LV", "LI", "LT", "LU", "MT", "NL", "NO", "PL", "PT", "RO", "SK", "SI", "ES", "SE", "GB",
    ]

    @State private var country = EnableBankingConnectView.defaultCountry(region: Locale.current.region?.identifier)
    @State private var banks: [EnableBankingBank] = []
    /// The country `banks` was loaded for; nil while loading or after a failure.
    @State private var loadedCountry: String?
    @State private var isLoadingBanks = false
    /// Why the bank list failed to load, shown in its place until a retry.
    @State private var bankLoadError: String?
    @State private var bankId: String?
    @State private var psuChoice = "personal"
    @State private var isWaiting = false
    @State private var authorizationTask: Task<Void, Never>?
    @State private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    @State private var remoteAccounts: [BankSyncRemoteAccount] = []
    @State private var errorMessage: String?
    @State private var syncSummary: String?
    @State private var linkTarget: BankSyncRemoteAccount?
    /// The budget account the link sheet linked, until the sheet has closed.
    @State private var linkedAccountId: String?

    init(preferredBankName: String? = nil) {
        self.preferredBankName = preferredBankName
    }

    var body: some View {
        List {
            if remoteAccounts.isEmpty {
                bankSection
                authorizeSection
            } else {
                remoteAccountsSection
            }
        }
        .navigationTitle("Connect Bank")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { authorizationTask?.cancel() }
        .sheet(item: $linkTarget, onDismiss: syncAfterLink, content: { remote in
            BankAccountLinkView(remote: remote, onLinked: { linkedAccountId = $0 })
                .environmentObject(budgetStore)
        })
        .alert("Bank Sync", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Pure helpers

    /// The Bank row pushes a screen; popping it re-runs the Country row's
    /// task, which must not wipe the bank picked there.
    nonisolated static func needsBankLoad(country: String, loadedCountry: String?) -> Bool {
        loadedCountry != country
    }

    nonisolated static func defaultCountry(region: String?) -> String {
        if let region, countries.contains(region) {
            return region
        }
        return "NL"
    }

    nonisolated static func countryName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    nonisolated static func title(for bank: EnableBankingBank) -> String {
        bank.beta == true
            ? String(format: String(localized: "%@ (beta)"), bank.name)
            : bank.name
    }

    /// The banks whose name matches what was typed in the search field; an
    /// empty query matches every bank.
    nonisolated static func filtered(_ banks: [EnableBankingBank], matching query: String) -> [EnableBankingBank] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return banks }
        return banks.filter { $0.name.localizedStandardContains(query) }
    }

    /// A bank that offers one usage type only gets that one; the picker is
    /// shown just when there is a real choice.
    nonisolated static func psuType(for bank: EnableBankingBank, choice: String) -> String {
        let types = bank.psuTypes ?? []
        if types.contains("personal"), types.contains("business") {
            return choice
        }
        return types.first ?? choice
    }

    /// `cancelled` means the sheet was closed, by the person or by `cancel()`;
    /// any other error means it never opened.
    nonisolated static func isSheetClosed(_ error: any Error) -> Bool {
        if case OpenIDAuthError.cancelled = error {
            return true
        }
        return false
    }

    /// The bank a linked account was made through, by the name the link stored.
    /// Only the loaded list is searched, so a bank from another country is nil.
    nonisolated static func bank(named name: String?, in banks: [EnableBankingBank]) -> EnableBankingBank? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return banks.first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// Nil when the bank shared at least one account to link.
    nonisolated static func noAccountsMessage(for accounts: [BankSyncRemoteAccount]) -> String? {
        accounts.isEmpty
            ? String(localized: "Your bank didn't share any accounts. Authorize again and select at least one account.")
            : nil
    }

    // MARK: - Sections

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

    private var bankSection: some View {
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
            } else if let bankLoadError {
                Text(bankLoadError)
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    Task { await loadBanks() }
                }
                .accessibilityIdentifier("enableBanking.retryBanks")
            } else if banks.isEmpty {
                Text("No banks found for this country.")
                    .foregroundStyle(.secondary)
            } else {
                NavigationLink {
                    EnableBankingBankList(banks: banks, selection: $bankId)
                } label: {
                    LabeledContent("Bank", value: selectedBank.map(Self.title(for:)) ?? String(localized: "Choose"))
                }
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
        } footer: {
            Text("You approve access on your bank's own page. Actuali never sees your bank sign-in details.")
        }
    }

    private var authorizeSection: some View {
        Section {
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
            if let syncSummary {
                Text(syncSummary)
            } else {
                Text("Tap an account to link it to a budget account. Linked accounts import new transactions every time you sync.")
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

    private func loadBanks() async {
        guard Self.needsBankLoad(country: country, loadedCountry: loadedCountry) else { return }
        // Cleared with the list, so a pick cancelled mid-load and then undone
        // still loads again instead of leaving the list empty.
        loadedCountry = nil
        banks = []
        bankId = nil
        bankLoadError = nil
        isLoadingBanks = true
        let requested = country
        do {
            let loaded = try await budgetStore.enableBankingBanks(country: requested)
            // A newer country pick supersedes this load, whether it was
            // cancelled or, started by Try Again, simply finished late.
            guard !Task.isCancelled, requested == country else { return }
            banks = loaded
            loadedCountry = requested
            // Nothing is picked yet, so this either selects the account's bank
            // or, when it isn't in this country's list, leaves the choice open.
            bankId = Self.bank(named: preferredBankName, in: loaded)?.id
        } catch {
            guard !Task.isCancelled, requested == country else { return }
            // Shown in place of the list, with a way to try again: an alert
            // would leave "no banks for this country" behind it.
            bankLoadError = error.localizedDescription
        }
        isLoadingBanks = false
    }

    private func sync(accountIds: [String]) async {
        syncSummary = nil
        let outcome = await EnableBankingSyncView.runSync(of: accountIds, in: budgetStore)
        syncSummary = outcome.summary
        if let alert = outcome.alert {
            errorMessage = alert
        }
    }

    /// Upstream syncs on link, so a freshly linked account has its history at
    /// once; and a re-link otherwise keeps showing the old "re-authorize" status.
    /// Closing the sheet without linking syncs nothing.
    private func syncAfterLink() {
        guard let id = linkedAccountId else { return }
        linkedAccountId = nil
        Task { await sync(accountIds: [id]) }
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
        // Set before the first request, so the tap shows progress at once.
        isWaiting = true
        do {
            let start = try await budgetStore.startEnableBankingAuthorization(bank: bank, psuType: psuType)

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
            // end the wait. A sheet that never opened can't lead to an approval,
            // though, so that ends it.
            Task {
                do {
                    _ = try await authenticator.open(start.url, callbackScheme: OpenIDAuthenticator.callbackScheme)
                } catch {
                    guard !Self.isSheetClosed(error) else { return }
                    errorMessage = error.localizedDescription
                    authorizationTask?.cancel()
                }
            }
            // Dismiss the sheet once the server reports the outcome.
            defer { authenticator.cancel() }

            remoteAccounts = try await budgetStore.awaitEnableBankingAuthorization(state: start.state)
            if let message = Self.noAccountsMessage(for: remoteAccounts) {
                errorMessage = message
            }
        } catch is CancellationError {
            // Cancel button or leaving the screen.
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// The banks of the chosen country, searchable by name. A bank that is
/// picked here becomes the selection and the list closes.
private struct EnableBankingBankList: View {
    @Environment(\.dismiss) private var dismiss

    let banks: [EnableBankingBank]
    @Binding var selection: String?

    @State private var query = ""

    var body: some View {
        let matches = EnableBankingConnectView.filtered(banks, matching: query)
        List(matches) { bank in
            Button {
                selection = bank.id
                dismiss()
            } label: {
                HStack {
                    Text(EnableBankingConnectView.title(for: bank))
                        .foregroundStyle(Color.primary)
                    Spacer()
                    if bank.id == selection {
                        Image(systemName: "checkmark")
                            .accessibilityHidden(true)
                    }
                }
            }
            .accessibilityAddTraits(bank.id == selection ? .isSelected : [])
            .accessibilityIdentifier("enableBanking.bankOption.\(bank.id)")
        }
        .overlay {
            if matches.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle("Bank")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query)
    }
}
