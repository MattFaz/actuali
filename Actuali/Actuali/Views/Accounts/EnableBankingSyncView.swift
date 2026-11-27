import SwiftUI

/// Enable Banking runs through the user's Actual server, which holds the
/// credentials. This screen only reports whether the server is ready, sends the
/// person to their bank to approve access, and then links what the bank returns.
struct EnableBankingSyncView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    enum Readiness: Equatable {
        case checking, unavailable, notConfigured, ready
        /// The status check itself failed (offline, say), which says nothing
        /// about what the server offers.
        case failed(String)
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
    /// The country `banks` was loaded for; nil while loading or after a failure.
    @State private var loadedCountry: String?
    @State private var isLoadingBanks = false
    @State private var bankId: String?
    @State private var psuChoice = "personal"
    @State private var isWaiting = false
    @State private var authorizationTask: Task<Void, Never>?
    @State private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    @State private var remoteAccounts: [BankSyncRemoteAccount] = []
    @State private var errorMessage: String?
    @State private var linkTarget: BankSyncRemoteAccount?
    /// The budget account the link sheet linked, until the sheet has closed.
    @State private var linkedAccountId: String?

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

    nonisolated static func readiness(for status: Bool?) -> Readiness {
        guard let status else { return .unavailable }
        return status ? .ready : .notConfigured
    }

    /// A failed status check gets its own state; cancellation (leaving the
    /// screen) isn't a failure, so it yields nil.
    nonisolated static func readiness(failure error: any Error) -> Readiness? {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return nil
        }
        return .failed(error.localizedDescription)
    }

    /// The Bank picker pushes a screen; popping it re-runs the Country row's
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

    private var linkedAccounts: [BankSyncAccount] {
        budgetStore.bankSyncAccounts.filter { $0.source == .enableBanking }
    }

    private var linkedSection: some View {
        Section {
            ForEach(linkedAccounts) { account in
                Menu {
                    Button("Authorize Again") {
                        reauthorize(account)
                    }
                    .disabled(authorizationTask != nil || readiness != .ready)
                    .accessibilityIdentifier("enableBanking.reauthorize.\(account.id)")
                    Button("Unlink", role: .destructive) {
                        unlink(account)
                    }
                    .accessibilityIdentifier("enableBanking.unlink.\(account.id)")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        // Explicit styles keep the menu from tinting the row.
                        Text(account.name)
                            .foregroundStyle(.primary)
                        if let bank = account.institutionName {
                            Text(bank)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let lastSync = account.lastSync {
                            HStack(spacing: 4) {
                                Text("Last Bank Sync")
                                Text(lastSync, format: .relative(presentation: .named))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        if let endsBy = account.permissionEndsBy {
                            Text("Bank permission ends by \(endsBy.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let message = account.attentionMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
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
                Label {
                    Text("Sync Now")
                } icon: {
                    if budgetStore.isBankSyncing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
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
        case .failed(let message):
            Section {
                Text(message)
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    readiness = .checking
                    Task { await loadReadiness() }
                }
                .accessibilityIdentifier("enableBanking.retry")
            }
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
        // Re-appearing (the Bank picker popping, say) runs this again. A server
        // already known to be ready isn't asked twice, so a network blip can't
        // take the form away in the middle of picking a bank.
        guard readiness != .ready else { return }
        do {
            let status = try await budgetStore.enableBankingStatus()
            readiness = Self.readiness(for: status)
        } catch {
            if let failed = Self.readiness(failure: error) {
                readiness = failed
            }
            return
        }
        if readiness == .notConfigured {
            redirectURL = await budgetStore.enableBankingRedirectURL()
        }
    }

    private func loadBanks() async {
        guard Self.needsBankLoad(country: country, loadedCountry: loadedCountry) else { return }
        // Cleared with the list, so a pick cancelled mid-load and then undone
        // still loads again instead of leaving the list empty.
        loadedCountry = nil
        banks = []
        bankId = nil
        isLoadingBanks = true
        do {
            let loaded = try await budgetStore.enableBankingBanks(country: country)
            guard !Task.isCancelled else { return }
            banks = loaded
            loadedCountry = country
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
        // A sync already running reports for itself; this call would only
        // return an empty result that claims there was nothing to sync.
        guard !budgetStore.isBankSyncing else { return }
        do {
            // Shown even when clean, so the person sees the sync happened.
            errorMessage = try await budgetStore.syncBankAccounts(accountIds: accountIds).summary
        } catch {
            errorMessage = error.localizedDescription
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

    private func reauthorize(_ account: BankSyncAccount) {
        guard let bank = Self.bank(named: account.institutionName, in: banks) else {
            errorMessage = String(localized: "Choose this account's bank under Connect a Bank, then authorize it again.")
            return
        }
        bankId = bank.id
        authorize()
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
