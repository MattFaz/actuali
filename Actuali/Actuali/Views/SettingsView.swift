import SwiftUI
import UIKit
import UserNotifications

private let actualBudgetWebsiteURL = URL(string: "https://actualbudget.org")!
private let privacyPolicyURL = URL(string: "https://actuali.mfazz.com/privacy")!
private let contactEmailURL = URL(string: "mailto:actuali@mfazz.com")!
private let supportURL = URL(string: "https://actuali.mfazz.com/support")!
private let issueTrackerURL = URL(string: "https://github.com/MattFaz/actuali/issues")!

struct SettingsView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.scenePhase) private var scenePhase

    /// Every currency in Actual's loot-core currencies list, plus a few
    /// user-requested extras Actual lacks (AMD, NOK, NZD, ZAR). Sorted by
    /// code. Display-only — all budget math is currency-agnostic integer
    /// cents, and rendering uses the system formatter for the ISO code.
    private static let currencyOptions: [(symbol: String, code: String)] = [
        ("د.إ", "AED"),
        ("֏", "AMD"),
        ("Arg$", "ARS"),
        ("A$", "AUD"),
        ("R$", "BRL"),
        ("Br", "BYN"),
        ("C$", "CAD"),
        ("Fr", "CHF"),
        ("CLP$", "CLP"),
        ("CN¥", "CNY"),
        ("Col$", "COP"),
        ("₡", "CRC"),
        ("Kč", "CZK"),
        ("kr", "DKK"),
        ("RD$", "DOP"),
        ("ج.م", "EGP"),
        ("€", "EUR"),
        ("£", "GBP"),
        ("Q", "GTQ"),
        ("HK$", "HKD"),
        ("Ft", "HUF"),
        ("Rp", "IDR"),
        ("₪", "ILS"),
        ("₹", "INR"),
        ("﷼", "IRR"),
        ("J$", "JMD"),
        ("¥", "JPY"),
        ("₩", "KRW"),
        ("Rs.", "LKR"),
        ("L", "MDL"),
        ("MX$", "MXN"),
        ("RM", "MYR"),
        ("kr", "NOK"),
        ("NZ$", "NZD"),
        ("₱", "PHP"),
        ("Rs.", "PKR"),
        ("zł", "PLN"),
        ("ر.ق", "QAR"),
        ("lei", "RON"),
        ("дин", "RSD"),
        ("₽", "RUB"),
        ("ر.س", "SAR"),
        ("kr", "SEK"),
        ("S$", "SGD"),
        ("฿", "THB"),
        ("₺", "TRY"),
        ("NT$", "TWD"),
        ("₴", "UAH"),
        ("$", "USD"),
        ("$U", "UYU"),
        ("UZS", "UZS"),
        ("R", "ZAR")
    ]
    @State private var password = ""
    @State private var showingResetSyncConfirm = false
    @State private var showingDisconnectConfirm = false
    @State private var showingWalletImport = false
    @State private var budgetToUnlock: BudgetStore.RemoteBudget?
    @State private var showingBudgetSelectPrompt = false
    @State private var transactionNotificationsEnabled = TransactionNotificationSettings().isEnabled
    @State private var notificationPermissionDenied = false
    @State private var lastBackgroundRefresh = BackgroundRefreshStatus().lastRun
    @State private var refreshRequestError = BackgroundRefreshStatus().lastScheduleError
    @State private var confirmBackupOverBaseline = false

    /// Persists the opt-in and requests permission on enable. Background
    /// refresh runs regardless of this toggle (it keeps data fresh for
    /// everyone); only notification posting is gated on it.
    private var transactionNotificationsBinding: Binding<Bool> {
        Binding(
            get: { transactionNotificationsEnabled },
            set: { enabled in
                transactionNotificationsEnabled = enabled
                TransactionNotificationSettings().isEnabled = enabled
                if enabled {
                    Task { await enableTransactionNotifications() }
                } else {
                    notificationPermissionDenied = false
                }
            }
        )
    }

    private func enableTransactionNotifications() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        notificationPermissionDenied = !granted
    }

    /// Permission can change in the Settings app while we're backgrounded;
    /// re-check whenever the screen appears.
    private func refreshNotificationPermissionState() async {
        guard transactionNotificationsEnabled else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationPermissionDenied = status == .denied
    }

    private func reloadBackgroundRefreshStatus() {
        let status = BackgroundRefreshStatus()
        lastBackgroundRefresh = status.lastRun
        refreshRequestError = status.lastScheduleError
    }

    private static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        return "\(version) (\(build))"
    }

    private var budgetPickerBinding: Binding<String?> {
        Binding(
            get: {
                // The picker matches on the server fileId, but currentBudgetId
                // is the internal id — map through the local metadata.
                guard let budgetId = budgetStore.currentBudgetId,
                      let metadata = BudgetFileManager.shared.listLocalBudgets().first(where: { $0.id == budgetId }) else {
                    return nil
                }
                return metadata.cloudFileId
            },
            set: { newId in
                if let id = newId,
                   let budget = budgetStore.remoteBudgets.first(where: { $0.id == id }) {
                    Task {
                        await budgetStore.downloadBudget(budget)
                    }
                }
            }
        )
    }

    private func openBudget(_ budget: BudgetStore.RemoteBudget) {
        if budget.isEncrypted && EncryptionKeyManager.load(fileId: budget.id) == nil {
            budgetToUnlock = budget
        } else {
            Task { await budgetStore.downloadBudget(budget) }
        }
    }

    /// One-time nudge after connecting: surface budget selection so a fresh
    /// connection doesn't leave the user staring at empty tabs.
    private func promptBudgetSelectionIfNeeded() {
        if budgetStore.currentBudgetId == nil && !budgetStore.remoteBudgets.isEmpty {
            showingBudgetSelectPrompt = true
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server URL", text: $budgetStore.serverURL)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        .disabled(budgetStore.isConnected)
                        .accessibilityHint("Example: https://actual.example.com")

                    if !budgetStore.isConnected {
                        // Show the password field before probing, when password
                        // login is active, or when the first OpenID sign-in needs
                        // the server password (no owner yet).
                        if budgetStore.availableLoginMethods.isEmpty
                            || budgetStore.passwordLoginActive
                            || budgetStore.requiresServerPassword {
                            SecureField(
                                budgetStore.requiresServerPassword && !budgetStore.passwordLoginActive
                                    ? "Server password (first sign-in)"
                                    : "Password",
                                text: $password
                            )
                        }

                        Button("Connect") {
                            Task {
                                await budgetStore.connect()
                                guard budgetStore.error == nil else { return }
                                // Discover available auth methods, then log in with
                                // password directly when that's the active method.
                                await budgetStore.checkLoginMethods()
                                // A probe that couldn't reach the server has
                                // already explained why; don't repeat the same
                                // failure as a login attempt.
                                guard budgetStore.error == nil else { return }
                                if budgetStore.passwordLoginActive && !password.isEmpty {
                                    await budgetStore.login(password: password)
                                }
                            }
                        }
                        .disabled(budgetStore.serverURL.isEmpty || budgetStore.isLoading)

                        if budgetStore.supportsOpenIDLogin {
                            Button("Sign in with OpenID") {
                                Task {
                                    await budgetStore.loginWithOpenID(
                                        firstTimePassword: password.isEmpty ? nil : password
                                    )
                                }
                            }
                            .disabled(budgetStore.isLoading
                                || (budgetStore.requiresServerPassword && password.isEmpty))
                        }

                        Menu("Try the demo budget") {
                            Button("Envelope budget") {
                                Task { await budgetStore.loadDemoData() }
                            }
                            Button("Tracking budget") {
                                Task { await budgetStore.loadDemoData(tracking: true) }
                            }
                        }
                        .disabled(budgetStore.isLoading)

                        NavigationLink {
                            CustomHeadersEditor(headers: $budgetStore.customHeaders)
                        } label: {
                            HStack {
                                Text("Custom HTTP headers")
                                Spacer()
                                let count = budgetStore.customHeaders.filter {
                                    !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
                                }.count
                                if count > 0 {
                                    Text("\(count)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        HStack {
                            Text("Status")
                            Spacer()
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 8, height: 8)
                                Text("Connected")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button("Disconnect", role: .destructive) {
                            showingDisconnectConfirm = true
                        }
                    }
                } header: {
                    Text("Server Connection")
                } footer: {
                    if !budgetStore.isConnected {
                        Text("Example: https://actual.example.com\n\nBehind an auth proxy like Cloudflare Access? Add a service token under \u{201C}Custom HTTP headers.\u{201D}\n\nNo server? Tap \u{201C}Try the demo budget\u{201D} to explore the app with sample data. The demo runs entirely on this device \u{2014} it never connects to a server or touches a real budget.")
                    }
                }

                // Shown while connected OR while a budget is loaded without a
                // session (demo, offline): the Default Account row below must
                // stay reachable in both.
                if budgetStore.isConnected || budgetStore.currentBudgetId != nil {
                    Section {
                        if budgetStore.isConnected {
                            Picker("Budget", selection: budgetPickerBinding) {
                                // Placeholder until a budget is chosen — deliberately
                                // not offered again afterwards, so "None" can't be
                                // (re)selected.
                                if budgetPickerBinding.wrappedValue == nil {
                                    Text("Select a Budget").tag(nil as String?)
                                }
                                // Render a placeholder tag for the current cloudFileId
                                // when remoteBudgets hasn't loaded yet (or doesn't
                                // include it), so SwiftUI can match the selection
                                // and we don't get an "invalid selection" warning.
                                if let currentId = budgetPickerBinding.wrappedValue,
                                   !budgetStore.remoteBudgets.contains(where: { $0.id == currentId }) {
                                    Text(budgetStore.remoteBudgets.isEmpty ? "Loading…" : "Unknown")
                                        .tag(currentId as String?)
                                }
                                ForEach(budgetStore.remoteBudgets.filter { !$0.isEncrypted }) { budget in
                                    Text(budget.name).tag(budget.id as String?)
                                }
                            }
                            .disabled(budgetStore.downloadingBudgetId != nil)

                            ForEach(budgetStore.remoteBudgets.filter { $0.isEncrypted }) { budget in
                                Button {
                                    openBudget(budget)
                                } label: {
                                    HStack {
                                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                                        Text(budget.name)
                                        Spacer()
                                        if budgetStore.downloadingBudgetId == budget.id {
                                            ProgressView()
                                        }
                                    }
                                }
                                .disabled(budgetStore.downloadingBudgetId != nil)
                            }

                            if budgetStore.remoteBudgets.isEmpty && !budgetStore.isLoading {
                                Button("Refresh Budgets") {
                                    Task { await budgetStore.fetchRemoteBudgets() }
                                }
                            }
                        }

                        // Lives up here rather than under Preferences because
                        // it's the natural next step after choosing a budget —
                        // Shortcuts and Wallet automation can't post without
                        // it (GH #122).
                        if budgetStore.currentBudgetId != nil {
                            Picker("Default Account", selection: $budgetStore.defaultAccountId) {
                                Text("None").tag(nil as String?)
                                ForEach(budgetStore.accounts.filter { !$0.closed }) { account in
                                    Text(account.name).tag(account.id as String?)
                                }
                            }
                        }
                    } header: {
                        Text("Budget")
                    } footer: {
                        if budgetStore.currentBudgetId == nil {
                            if budgetStore.remoteBudgets.isEmpty && !budgetStore.isLoading {
                                Text("No budgets were found on your server. Create one in Actual Budget, then tap Refresh Budgets.")
                            } else {
                                Text("Select a budget to load it onto this device. The app stays empty until one is chosen.")
                            }
                        } else {
                            Text("New transactions, Siri Shortcuts, and Wallet automation use the Default Account when no account is chosen.")
                        }
                    }
                }

                Section {
                    Picker("Currency", selection: $budgetStore.currencyCode) {
                        // Empty code = no currency, matching Actual's
                        // defaultCurrencyCode convention. Amounts render as
                        // plain numbers.
                        Text("None").tag("")
                        ForEach(Self.currencyOptions, id: \.code) { option in
                            Text("\(option.symbol) \(option.code)").tag(option.code)
                        }
                    }

                    // Meaningless with no currency selected, so hidden there.
                    if !budgetStore.currencyCode.isEmpty {
                        Toggle("Symbol Only", isOn: $budgetStore.useNarrowCurrencySymbol)
                    }

                    Picker("Appearance", selection: $budgetStore.appearanceMode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }

                    Picker("Start Page", selection: $budgetStore.startTab) {
                        ForEach(StartTab.allCases) { tab in
                            Text(tab.label).tag(tab)
                        }
                    }

                    Picker("View Transactions As", selection: $budgetStore.transactionDisplayMode) {
                        ForEach(TransactionDisplayMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }

                    Toggle("Budget Progress Bars", isOn: $budgetStore.showBudgetProgressBars)

                    Toggle("Overspent Badge", isOn: $budgetStore.showOverspentBadge)

                    Toggle("Hide Balances", isOn: $budgetStore.hideBalances)

                    // Meaningless against servers that predate payee
                    // locations (< 26.4.0), so hidden there.
                    if budgetStore.payeeLocationWritesEnabled {
                        Toggle("Record Payee Locations", isOn: $budgetStore.recordPayeeLocations)

                        // Clearing needs the same >= 26.4.0 server, so this
                        // lives inside the gate too (GH #147).
                        NavigationLink {
                            PayeeLocationsView()
                        } label: {
                            Text("Payee Locations")
                        }
                    }

                    if budgetStore.currentBudgetId != nil {
                        NavigationLink {
                            CardAccountMappingsView()
                        } label: {
                            HStack {
                                Text("Card & Account Mappings")
                                Spacer()
                                if !budgetStore.cardAccountMappings.isEmpty {
                                    Text("\(budgetStore.cardAccountMappings.count)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Preferences")
                } footer: {
                    if budgetStore.currencyCode.isEmpty {
                        Text("Hide Balances masks amounts across the app. Start Page takes effect the next time the app opens.")
                    } else {
                        Text("Symbol Only shows amounts with just the currency symbol — $ instead of NZ$. Hide Balances masks amounts across the app. Start Page takes effect the next time the app opens.")
                    }
                }

                Section {
                    Toggle("Post Scheduled Transactions", isOn: $budgetStore.postScheduledTransactions)
                } footer: {
                    Text("When enabled, scheduled transactions that are due are posted automatically when the app opens — the same as opening the Actual web app. Transactions are created on your server.")
                }

                if budgetStore.currentBudgetId != nil {
                    Section("Sync") {
                        HStack {
                            Text("Status")
                            Spacer()
                            switch budgetStore.syncState {
                            case .idle:
                                Text("Idle")
                                    .foregroundStyle(.secondary)
                            case .syncing:
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                    Text("Syncing...")
                                        .foregroundStyle(.secondary)
                                }
                            case .offline:
                                Text("Offline")
                                    .foregroundStyle(.orange)
                            case .error:
                                Text("Error")
                                    .foregroundStyle(.red)
                            }
                        }

                        if case let .error(message) = budgetStore.syncState {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        
                        if budgetStore.syncDetachedByRestore {
                            Text("Sync is disconnected because a backup was restored. Re-download the budget from your server to resume syncing — that replaces the restored data with the server copy.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        if let lastSync = budgetStore.lastSyncTime {
                            HStack {
                                Text("Last Sync")
                                Spacer()
                                Text(lastSync, style: .relative)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // Diagnostic: "Never" (or a stale time) with Background
                        // App Refresh enabled usually means the app was
                        // force-quit — iOS won't run the task until next launch.
                        HStack {
                            Text("Last Background Refresh")
                            Spacer()
                            if let lastBackgroundRefresh {
                                Text(lastBackgroundRefresh, style: .relative)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Never")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // Distinguishes "the app never asked for a wake" from
                        // "iOS never granted one": a stale row above with no
                        // footnote here points at the system or device
                        // settings, not the app. Hidden while submits succeed
                        // (the common case — we resubmit on every activation).
                        if let refreshRequestError {
                            Text("Refresh request failed: \(refreshRequestError)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        Button("Sync Now") {
                            Task {
                                await budgetStore.sync()
                            }
                        }
                        .disabled(budgetStore.syncState == .syncing)

                        if case .error = budgetStore.syncState {
                            Button("Reset Sync State", role: .destructive) {
                                showingResetSyncConfirm = true
                            }
                            .disabled(budgetStore.syncState == .syncing)
                        }
                    }
                }
                
                if budgetStore.currentBudgetId != nil {
                    Section {
                        NavigationLink {
                            BackupListView()
                        } label: {
                            HStack {
                                Text("Backups")
                                Spacer()
                                if !budgetStore.backups.isEmpty {
                                    Text("\(budgetStore.backups.count)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Button("Back Up Now") {
                            if budgetStore.isViewingBackup {
                                confirmBackupOverBaseline = true
                            } else {
                                Task { await budgetStore.makeBackupNow() }
                            }
                        }
                        .confirmationDialog(
                            "Back up the restored data?",
                            isPresented: $confirmBackupOverBaseline,
                            titleVisibility: .visible
                        ) {
                            Button("Back Up", role: .destructive) {
                                Task { await budgetStore.makeBackupNow() }
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This makes the restored data your current budget and removes the option to revert to the version from before you loaded a backup.")
                        }
                    } header: {
                        Text("Backups")
                    } footer: {
                        // No cadence promise — iOS can't run a 15-minute
                        // background timer (plan D2).
                        Text("Backups are stored on this device. One is taken automatically when you leave the app.")
                    }
                    .task { await budgetStore.refreshBackups() }
                }

                Section {
                    Toggle("New Transaction Alerts", isOn: transactionNotificationsBinding)

                    if notificationPermissionDenied {
                        Button("Open Settings to Allow Notifications") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    if notificationPermissionDenied {
                        Text("Notifications are turned off for Actuali in the Settings app, so transaction alerts can't be delivered.")
                    } else {
                        Text("Get notified when transactions from bank sync or other devices arrive, so you can categorize them. iOS checks a few times a day and requires Background App Refresh.")
                    }
                }

                Section {
                    NavigationLink {
                        WalletAutomationView()
                    } label: {
                        Label("Log Wallet Payments Automatically", systemImage: "wallet.pass")
                    }
                    if WalletImportView.isSupported {
                        Button {
                            showingWalletImport = true
                        } label: {
                            Label("Import Wallet Transactions", systemImage: "square.and.arrow.down")
                        }
                    }
                } header: {
                    Text("Automations")
                } footer: {
                    if WalletImportView.isSupported {
                        Text("Set up a Shortcuts automation that logs tap-to-pay purchases from Apple Wallet, or import Apple Card, Apple Cash and Savings transactions directly.")
                    } else {
                        Text("Set up a Shortcuts automation that logs tap-to-pay purchases from Apple Wallet.")
                    }
                }

                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Self.appVersion)
                            .foregroundStyle(.secondary)
                    }

                    Link("Privacy Policy", destination: privacyPolicyURL)

                    Link("Contact", destination: contactEmailURL)

                    Link("Report an Issue", destination: issueTrackerURL)

                    Link("Support", destination: supportURL)

                    Link("Actual Budget Website", destination: actualBudgetWebsiteURL)
                } header: {
                    Text("About")
                }
            }
            .readableWidth()
            .navigationTitle("Settings")
            .contentMargins(.horizontal, 6, for: .scrollContent)
            .task {
                reloadBackgroundRefreshStatus()
                await refreshNotificationPermissionState()
            }
            // The background refresh task fires while the app is suspended —
            // same process, so the @State snapshot taken at launch never
            // re-reads on its own and would show "Never" indefinitely.
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    reloadBackgroundRefreshStatus()
                }
            }
            .sheet(item: $budgetToUnlock) { budget in
                EncryptionPasswordSheet(budget: budget, budgetStore: budgetStore)
            }
            .sheet(isPresented: $showingWalletImport) {
                WalletImportView()
                    .environmentObject(budgetStore)
            }
            .overlay {
                if budgetStore.isLoading {
                    ProgressView()
                }
            }
            .confirmationDialog(
                "Disconnect and remove data?",
                isPresented: $showingDisconnectConfirm,
                titleVisibility: .visible
            ) {
                Button("Disconnect & Remove Data", role: .destructive) {
                    budgetStore.logout()
                    password = ""
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Signs out and deletes this device's copy of your budgets. Any changes that haven't synced to the server yet will be lost. Your data on the server is not affected.")
            }
            .confirmationDialog(
                "Reset sync state?",
                isPresented: $showingResetSyncConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset & Resync", role: .destructive) {
                    Task {
                        await budgetStore.resetSyncState()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Discards the local sync marker and re-checks your budget against the server, pulling down anything missing. Local edits are re-sent rather than discarded, but a large budget can take a moment to reconcile.")
            }
            .confirmationDialog(
                "Select a Budget",
                isPresented: $showingBudgetSelectPrompt,
                titleVisibility: .visible
            ) {
                ForEach(budgetStore.remoteBudgets) { budget in
                    Button(budget.name) {
                        openBudget(budget)
                    }
                }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("You're connected! Choose which budget to load onto this device.")
            }
            .task {
                if budgetStore.isConnected {
                    await budgetStore.fetchRemoteBudgets()
                    promptBudgetSelectionIfNeeded()
                }
            }
            .onChange(of: budgetStore.isConnected) { _, isConnected in
                if isConnected {
                    Task {
                        await budgetStore.fetchRemoteBudgets()
                        promptBudgetSelectionIfNeeded()
                    }
                }
            }
        }
    }
}

/// Editor for user-defined HTTP headers sent on every server request. Edits a
/// local draft and commits back to the bound array on disappear, so the store
/// (and its Keychain write) is only touched once per visit rather than per
/// keystroke.
struct CustomHeadersEditor: View {
    @Binding var headers: [CustomHeader]
    @State private var draft: [CustomHeader] = []

    var body: some View {
        Form {
            Section {
                ForEach($draft) { $header in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Header name", text: $header.name)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.subheadline.weight(.medium))
                        TextField("Value", text: $header.value)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { draft.remove(atOffsets: $0) }

                Button {
                    draft.append(CustomHeader())
                } label: {
                    Label("Add header", systemImage: "plus")
                }
            } footer: {
                Text("Sent with every request to your server. For Cloudflare Access, add a service token as two headers: CF-Access-Client-Id and CF-Access-Client-Secret.")
            }
        }
        .navigationTitle("Custom HTTP Headers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .onAppear {
            if draft.isEmpty { draft = headers }
        }
        .onDisappear {
            let cleaned = draft.filter {
                !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
            }
            if cleaned != headers {
                headers = cleaned
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(BudgetStore.previewInstance())
}
