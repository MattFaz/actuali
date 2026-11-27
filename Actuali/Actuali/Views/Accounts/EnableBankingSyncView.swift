import SwiftUI

/// Enable Banking runs through the user's Actual server, which holds the
/// credentials. This screen manages the accounts already linked and, once the
/// server is ready, leads to `EnableBankingConnectView` to connect a bank.
struct EnableBankingSyncView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    enum Readiness: Equatable {
        case checking, unavailable, notConfigured, ready
        /// The status check itself failed (offline, say), which says nothing
        /// about what the server offers.
        case failed(String)
    }

    /// What "Reauthorize" pushes: the connect screen with the account's
    /// bank already chosen.
    private struct Reauthorization: Hashable {
        let bankName: String?
    }

    @State private var readiness = Readiness.checking
    @State private var redirectURL: URL?
    @State private var errorMessage: String?
    /// A clean sync's outcome, shown in the footer where Sync Now was tapped.
    @State private var syncSummary: String?
    @State private var unlinkTarget: BankSyncAccount?
    @State private var reauthorization: Reauthorization?

    var body: some View {
        List {
            statusSection
            if !linkedAccounts.isEmpty {
                linkedSection
            }
            if readiness == .ready {
                connectSection
            }
        }
        .navigationTitle("Enable Banking")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadReadiness() }
        .navigationDestination(item: $reauthorization) { target in
            EnableBankingConnectView(preferredBankName: target.bankName)
        }
        .confirmationDialog(
            "Unlink \(unlinkTarget?.name ?? "")?",
            isPresented: unlinkDialogBinding,
            titleVisibility: .visible,
            presenting: unlinkTarget
        ) { account in
            Button("Unlink", role: .destructive) { unlink(account) }
                .accessibilityIdentifier("enableBanking.unlink.confirm")
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This account stops importing from your bank. Its transactions stay. To link it again you need to authorize the bank again.")
        }
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

    /// A clean sync's summary on one line, for a footer. Nil when the sync
    /// reported problems, which the alert shows so they wait to be read.
    nonisolated static func cleanSummary(of result: BudgetStore.BankSyncResult) -> String? {
        result.problems.isEmpty
            ? result.summary.replacingOccurrences(of: "\n\n", with: " ")
            : nil
    }

    // MARK: - Sections

    private var linkedAccounts: [BankSyncAccount] {
        budgetStore.bankSyncAccounts.filter { $0.source == .enableBanking }
    }

    private var linkedSection: some View {
        Section {
            ForEach(linkedAccounts) { account in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name)
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
                        if let linkedAt = account.linkedAt {
                            Text("Authorized on \(linkedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let message = account.attentionMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("enableBanking.linked.\(account.id)")
                    Spacer()
                    // Only the dots open the menu: a menu on the whole row tints
                    // it and hides the account while the menu is up.
                    Menu {
                        Button("Reauthorize") {
                            reauthorization = Reauthorization(bankName: account.institutionName)
                        }
                        .disabled(readiness != .ready)
                        .accessibilityIdentifier("enableBanking.reauthorize.\(account.id)")
                        Button("Unlink", role: .destructive) {
                            unlinkTarget = account
                        }
                        .accessibilityIdentifier("enableBanking.unlink.\(account.id)")
                    } label: {
                        Label("More", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    // Keeps the tap on the dots instead of the whole row.
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("enableBanking.linkedMenu.\(account.id)")
                }
                // A full swipe slides the row away as if it were already deleted, but the
                // confirmation can still be cancelled.
                .swipeActions(allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        unlinkTarget = account
                    } label: {
                        Text("Unlink")
                    }
                }
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
        } footer: {
            if let syncSummary {
                Text(syncSummary)
            } else {
                Text("Bank permissions last up to 90 days. Authorize a bank again before then to keep syncing.")
            }
        }
    }

    private var connectSection: some View {
        Section {
            NavigationLink {
                EnableBankingConnectView()
            } label: {
                Label("Connect Bank", systemImage: "plus")
            }
            .accessibilityIdentifier("enableBanking.connect")
        }
    }

    /// What the server said about Enable Banking, first on the screen because
    /// everything below depends on it.
    @ViewBuilder
    private var statusSection: some View {
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
            Section {
                Label {
                    Text("Enable Banking is set up")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .accessibilityIdentifier("enableBanking.status")
            }
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

    // MARK: - Actions

    private var errorAlertBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: {
            if !$0 {
                errorMessage = nil
            }
        })
    }

    private var unlinkDialogBinding: Binding<Bool> {
        Binding(get: { unlinkTarget != nil }, set: {
            if !$0 {
                unlinkTarget = nil
            }
        })
    }

    private func loadReadiness() async {
        // Popping back from the connect screen runs this again. A server
        // already known to be ready isn't asked twice, so a network blip can't
        // take the Connect Bank row away.
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
        syncSummary = nil
        do {
            let result = try await budgetStore.syncBankAccounts(accountIds: accountIds)
            if let line = Self.cleanSummary(of: result) {
                syncSummary = line
            } else {
                errorMessage = result.summary
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
