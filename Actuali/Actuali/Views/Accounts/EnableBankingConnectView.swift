import SwiftUI
import UserNotifications

/// One bank authorization: pick the bank, send the person to it to approve
/// access, then link the accounts it returns. The Actual server holds the
/// Enable Banking credentials, so this only carries the request through.
struct EnableBankingConnectView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    /// Set when a linked account's bank is authorized again: that bank starts
    /// out chosen, and the bank's answer renews the link instead of asking
    /// where it goes.
    let reauthorizingAccountId: String?

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
    /// The attempt in progress, from the tap until the bank's answer is in.
    @State private var authorizationTask: Task<Void, Never>?
    @State private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    @State private var remoteAccounts: [BankSyncRemoteAccount] = []
    @State private var errorMessage: String?
    @State private var syncSummary: String?
    @State private var linkTarget: BankSyncRemoteAccount?
    /// The budget account the link sheet linked, until the sheet has closed.
    @State private var linkedAccountId: String?
    /// The only account the bank returned, while nothing imports from it yet.
    /// With one account there is no list to pick from, so the screen asks
    /// where it goes straight away.
    @State private var directTarget: BankSyncRemoteAccount?
    /// Whether the country, bank and usage type are asked for. Connecting a
    /// bank starts there; reauthorizing knows its bank and only falls back to
    /// the form when it can't go straight to it.
    @State private var showsForm: Bool
    /// While the account picked for a reauthorized link is being linked.
    @State private var isChoosing = false

    init(reauthorizingAccountId: String? = nil) {
        self.reauthorizingAccountId = reauthorizingAccountId
        _showsForm = State(initialValue: reauthorizingAccountId == nil)
    }

    var body: some View {
        List {
            if !remoteAccounts.isEmpty {
                resultSections
            } else if showsForm {
                bankSection
                authorizeSection
            } else {
                openingSection
            }
        }
        .task { await startReauthorization() }
        .navigationTitle(reauthorizingAccountId == nil ? Text("Connect Bank") : Text("Reauthorize"))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { authorizationTask?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            // Back in the app, the banner that called the person here is spent.
            if phase == .active {
                UNUserNotificationCenter.current()
                    .removeDeliveredNotifications(withIdentifiers: [BankAuthorizationNotifier.requestIdentifier])
            }
        }
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
        bank.offersBothUsageTypes ? choice : bank.psuTypes?.first ?? choice
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
        banks.first { EnableBankingLinks.sameName($0.name, name) }
    }

    /// How much of what the bank returned feeds a budget account, which is
    /// what tells someone back from their bank whether anything is left to do.
    enum LinkProgress: Equatable {
        case none, some, all
    }

    nonisolated static func linkProgress(
        of remotes: [BankSyncRemoteAccount],
        linked: [BankSyncAccount]
    ) -> LinkProgress {
        let count = remotes.count { $0.link(in: linked) != nil }
        return count == 0 ? .none : count == remotes.count ? .all : .some
    }

    /// The account to ask about straight away: the only one the bank
    /// returned, if nothing imports from it yet.
    nonisolated static func directTarget(
        of remotes: [BankSyncRemoteAccount],
        linked: [BankSyncAccount]
    ) -> BankSyncRemoteAccount? {
        guard remotes.count == 1, let only = remotes.first, only.link(in: linked) == nil else { return nil }
        return only
    }

    /// The top line of the result: what just happened, naming the bank so the
    /// accounts below are plainly that bank's.
    nonisolated static func headline(bank: String, renewed: Bool) -> String {
        String(
            format: renewed ? String(localized: "%@ is authorized again") : String(localized: "%@ is connected"),
            bank
        )
    }

    /// What is on the screen after connecting a bank and what to do with it.
    nonisolated static func nextStep(bank: String, progress: LinkProgress, asksDirectly: Bool) -> String {
        if progress == .all {
            return String(localized: "Every account is set up. New transactions import when you sync.")
        }
        return String(
            format: asksDirectly
                ? String(localized: "This is your account at %@. Choose where its transactions go.")
                : String(localized: "These are your accounts at %@. Pick the ones you want in your budget."),
            bank
        )
    }

    /// Where reauthorizing an account stands once the bank has answered. It
    /// is about that one account only: whatever else the bank returned belongs
    /// under Connect Bank, not here.
    enum ReauthorizationStep: Equatable {
        /// The account imports from one of the returned accounts again.
        case done
        /// Nothing could be paired for certain, so the person picks which of
        /// these the account imported from.
        case ask([BankSyncRemoteAccount])
        /// The bank returned nothing the account could import from.
        case missing
    }

    nonisolated static func reauthorizationStep(
        of remotes: [BankSyncRemoteAccount],
        reauthorizing accountId: String,
        linked: [BankSyncAccount]
    ) -> ReauthorizationStep {
        if remotes.contains(where: { $0.link(in: linked)?.id == accountId }) {
            return .done
        }
        let candidates = remotes.filter { $0.link(in: linked) == nil }
        return candidates.isEmpty ? .missing : .ask(candidates)
    }

    /// Nil when the bank shared at least one account to link.
    nonisolated static func noAccountsMessage(for accounts: [BankSyncRemoteAccount]) -> String? {
        accounts.isEmpty
            ? String(localized: "Your bank didn't share any accounts. Authorize again and select at least one account.")
            : nil
    }

    // MARK: - Sections

    private static let sortedCountries = countries.sorted {
        countryName($0).localizedCompare(countryName($1)) == .orderedAscending
    }

    private var isWaiting: Bool {
        authorizationTask != nil
    }

    private var selectedBank: EnableBankingBank? {
        banks.first { $0.id == bankId }
    }

    private var bankSection: some View {
        Section {
            Picker("Country", selection: $country) {
                ForEach(Self.sortedCountries, id: \.self) { code in
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

            if selectedBank?.offersBothUsageTypes == true {
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
                waitingRows
            }
        } footer: {
            Text(returnNote)
        }
    }

    /// Always under the way to the bank: once the bank's page is up it covers
    /// this screen, so this has to be read before leaving.
    private var returnNote: String {
        String(localized: "After you approve, come back to Actuali. Your banking app or browser may not return you here by itself, and the result shows on this screen.")
    }

    @ViewBuilder
    private var waitingRows: some View {
        HStack {
            ProgressView()
            Text("Waiting for your bank…")
                .foregroundStyle(.secondary)
        }
        Button("Cancel", role: .cancel) {
            // Where a reauthorization skipped the form, cancelling leads to it.
            showsForm = true
            authorizationTask?.cancel()
        }
        .accessibilityIdentifier("enableBanking.cancel")
    }

    /// The bank whose accounts are on screen.
    private var bankName: String {
        selectedBank?.name ?? remoteAccounts.first?.institutionName ?? ""
    }

    private var skipNote: String {
        String(localized: "Accounts you skip are not imported. To add one later, connect this bank again.")
    }

    /// Shown instead of the form while a reauthorization goes straight to
    /// the account's bank.
    private var openingSection: some View {
        Section {
            waitingRows
        } footer: {
            Text(returnNote)
        }
    }

    private func resultHeader(_ title: String, _ subtitle: String, isProblem: Bool = false) -> some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(isProblem ? Color.orange : Color.green)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("enableBanking.result")
        }
        .listRowBackground(Color.clear)
    }

    private var doneSection: some View {
        Section {
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("enableBanking.done")
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var resultSections: some View {
        if let reauthorizingAccountId {
            reauthorizationSections(for: reauthorizingAccountId)
        } else {
            connectionSections
        }
    }

    /// After reauthorizing: whether the account is back, and nothing about
    /// the bank's other accounts, which nobody asked to set up here.
    @ViewBuilder
    private func reauthorizationSections(for accountId: String) -> some View {
        let linked = budgetStore.bankSyncAccounts
        let accountName = budgetStore.accounts.first { $0.id == accountId }?.name ?? ""
        switch Self.reauthorizationStep(of: remoteAccounts, reauthorizing: accountId, linked: linked) {
        case .done:
            resultHeader(
                Self.headline(bank: bankName, renewed: true),
                String(localized: "Your linked accounts keep importing.")
            )
            Section {
                ForEach(remoteAccounts) { remote in
                    if let link = remote.link(in: linked) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.name)
                                Text("Imports from \(remote.name)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(.green)
                                .accessibilityHidden(true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("enableBanking.renewed.\(link.id)")
                    }
                }
            } header: {
                Text("Linked Accounts")
            } footer: {
                if let syncSummary {
                    Text(syncSummary)
                }
            }
            doneSection
        case .ask(let candidates):
            resultHeader(
                Self.headline(bank: bankName, renewed: true),
                String(
                    format: String(localized: "Actuali can't tell which of these accounts %@ imported from. Pick the same one as before."),
                    accountName
                )
            )
            Section {
                ForEach(candidates) { remote in
                    Button {
                        choose(remote, for: accountId)
                    } label: {
                        HStack {
                            Text(remote.name)
                            Spacer()
                            if let cents = remote.balanceCents {
                                Text(budgetStore.displayBalance(cents))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        // A plain button only takes taps on what is drawn.
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("enableBanking.candidate.\(remote.id)")
                }
            } header: {
                Text("Which account does \(accountName) import from?")
            }
            .disabled(isChoosing)
        case .missing:
            resultHeader(
                String(localized: "Account not found"),
                String(
                    format: String(localized: "%@ didn't share the account that %@ imports from. Authorize again and select it at your bank."),
                    bankName, accountName
                ),
                isProblem: true
            )
            Section {
                Button("Try Again") {
                    remoteAccounts = []
                    authorize()
                }
                .accessibilityIdentifier("enableBanking.reauthorizeAgain")
            }
        }
    }

    /// After connecting a bank: what happened and what to do, then the bank's
    /// accounts, each saying whether it imports yet.
    @ViewBuilder
    private var connectionSections: some View {
        let progress = Self.linkProgress(of: remoteAccounts, linked: budgetStore.bankSyncAccounts)
        resultHeader(
            Self.headline(bank: bankName, renewed: false),
            Self.nextStep(bank: bankName, progress: progress, asksDirectly: directTarget != nil)
        )

        if let directTarget {
            Section {
                LabeledContent(directTarget.name) {
                    if let cents = directTarget.balanceCents {
                        Text(budgetStore.displayBalance(cents))
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Your Accounts at \(bankName)")
            }
            BankAccountLinkChoices(remote: directTarget, footer: skipNote) { accountId in
                self.directTarget = nil
                Task { await sync(accountIds: [accountId]) }
            }
        } else {
            Section {
                ForEach(remoteAccounts) { remote in
                    Button {
                        linkTarget = remote
                    } label: {
                        BankRemoteAccountRow(remote: remote, showsInstitution: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("enableBanking.remoteAccount.\(remote.id)")
                }
            } header: {
                Text("Your Accounts at \(bankName)")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let syncSummary {
                        Text(syncSummary)
                    }
                    if progress != .all {
                        Text(skipNote)
                    }
                }
            }
            if progress != .none {
                doneSection
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
            let reauthorizing = reauthorizingAccountId.flatMap(budgetStore.bankSyncAccount(forAccountId:))
            bankId = Self.bank(named: reauthorizing?.institutionName, in: loaded)?.id
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

    /// Moves each renewed link to the account id the bank just issued and
    /// returns the budget accounts it moved. A link that fails is reported and
    /// its account stays in the list to link by hand.
    private func renew(_ renewals: [String: BankSyncRemoteAccount]) async -> [String] {
        var renewed: [String] = []
        for (accountId, remote) in renewals {
            do {
                try await budgetStore.linkBankAccount(accountId: accountId, to: remote)
                renewed.append(accountId)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        return renewed
    }

    /// The account picked for a reauthorized link: move the link there and
    /// sync it, as a renewal found by itself would.
    private func choose(_ remote: BankSyncRemoteAccount, for accountId: String) {
        isChoosing = true
        Task {
            defer { isChoosing = false }
            let renewed = await renew([accountId: remote])
            if !renewed.isEmpty {
                await sync(accountIds: renewed)
            }
        }
    }

    /// Reauthorizing goes straight to the account's bank; the form is only
    /// for when that can't be done.
    ///
    /// ponytail: a link stores its bank's name and nothing else, so the
    /// country is taken to be this device's region and the usage type to be
    /// personal. A bank from elsewhere lands on the form, and a wrong usage
    /// type means cancelling at the bank to get to it. Upgrade path: remember
    /// the country and usage type an account was authorized with.
    private func startReauthorization() async {
        guard !showsForm, remoteAccounts.isEmpty, authorizationTask == nil else { return }
        await loadBanks()
        // Cancel was tapped while the list loaded.
        guard !showsForm else { return }
        authorize()
    }

    private func authorize() {
        // `loadBanks` picked a reauthorized account's bank if this country's
        // list has it. Without a bank there is nowhere to go straight to, and
        // the screen must not be left waiting for nothing.
        guard let bank = selectedBank else {
            showsForm = true
            return
        }
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
            authorizationTask = nil
            // An attempt that ended without accounts leaves the form to retry
            // from, also where a reauthorization had skipped it.
            if remoteAccounts.isEmpty {
                showsForm = true
            }
        }
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
                    _ = try await authenticator.open(start.url)
                } catch {
                    guard !Self.isSheetClosed(error) else { return }
                    errorMessage = error.localizedDescription
                    authorizationTask?.cancel()
                }
            }
            let accounts: [BankSyncRemoteAccount]
            do {
                // Dismiss the sheet once the server reports the outcome.
                defer { authenticator.cancel() }
                accounts = try await budgetStore.awaitEnableBankingAuthorization(state: start.state)
            }
            // The bank's last page belongs to the bank or the Actual server and
            // can't reopen this app, so someone still over there gets a banner.
            if UIApplication.shared.applicationState != .active {
                await BankAuthorizationNotifier.notifyApproved()
            }
            let renewals = await budgetStore.enableBankingRenewals(
                of: accounts, bankName: bank.name, reauthorizing: reauthorizingAccountId
            )
            // Its own task: leaving the screen cancels this one, which must
            // not stop a renewal between two links.
            let renewed = await Task { await renew(renewals) }.value
            // Shown only now, so a renewed link never appears as not imported first.
            if reauthorizingAccountId == nil {
                directTarget = Self.directTarget(of: accounts, linked: budgetStore.bankSyncAccounts)
            }
            remoteAccounts = accounts
            if let message = Self.noAccountsMessage(for: accounts) {
                errorMessage = message
            }
            if !renewed.isEmpty {
                Task { await sync(accountIds: renewed) }
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
