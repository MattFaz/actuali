import SwiftUI

private let actualBudgetWebsiteURL = URL(string: "https://actualbudget.org")!
private let privacyPolicyURL = URL(string: "https://actuali.mfazz.com/privacy")!
private let contactEmailURL = URL(string: "mailto:actuali@mfazz.com")!
private let supportURL = URL(string: "https://actuali.mfazz.com/support")!
private let issueTrackerURL = URL(string: "https://github.com/MattFaz/actuali/issues")!

struct SettingsView: View {
    @EnvironmentObject var budgetStore: BudgetStore

    /// Curated starter list of display currencies, matching common Actual
    /// deployments. Display-only — all budget math is currency-agnostic
    /// integer cents.
    private static let currencyOptions: [(symbol: String, code: String)] = [
        ("$", "USD"),
        ("€", "EUR"),
        ("£", "GBP"),
        ("¥", "JPY"),
        ("C$", "CAD"),
        ("A$", "AUD"),
        ("₹", "INR"),
        ("Fr", "CHF")
    ]
    @State private var password = ""
    @State private var showingResetSyncConfirm = false
    @State private var budgetToUnlock: BudgetStore.RemoteBudget?
    @State private var showingBudgetSelectPrompt = false

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

                        Button("Try the demo budget") {
                            Task { await budgetStore.loadDemoData() }
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
                            budgetStore.logout()
                            password = ""
                        }
                    }
                } header: {
                    Text("Server Connection")
                } footer: {
                    if !budgetStore.isConnected {
                        Text("Example: https://actual.example.com\n\nBehind an auth proxy like Cloudflare Access? Add a service token under \u{201C}Custom HTTP headers.\u{201D}\n\nNo server? Tap \u{201C}Try the demo budget\u{201D} to explore the app with sample data.")
                    }
                }

                if budgetStore.isConnected {
                    Section {
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
                    } header: {
                        Text("Budget")
                    } footer: {
                        if budgetStore.currentBudgetId == nil {
                            if budgetStore.remoteBudgets.isEmpty && !budgetStore.isLoading {
                                Text("No budgets were found on your server. Create one in Actual Budget, then tap Refresh Budgets.")
                            } else {
                                Text("Select a budget to load it onto this device. The app stays empty until one is chosen.")
                            }
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

                    Toggle("Budget Progress Bars", isOn: $budgetStore.showBudgetProgressBars)

                    Toggle("Overspent Badge", isOn: $budgetStore.showOverspentBadge)

                    if budgetStore.currentBudgetId != nil {
                        Picker("Default Account", selection: $budgetStore.defaultAccountId) {
                            Text("None").tag(nil as String?)
                            ForEach(budgetStore.accounts.filter { !$0.closed }) { account in
                                Text(account.name).tag(account.id as String?)
                            }
                        }
                    }
                } header: {
                    Text("Preferences")
                } footer: {
                    Text("Start Page takes effect the next time the app opens.")
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

                        if let lastSync = budgetStore.lastSyncTime {
                            HStack {
                                Text("Last Sync")
                                Spacer()
                                Text(lastSync, style: .relative)
                                    .foregroundStyle(.secondary)
                            }
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

                Section {
                    NavigationLink {
                        WalletAutomationView()
                    } label: {
                        Label("Log Wallet Payments Automatically", systemImage: "wallet.pass")
                    }
                } header: {
                    Text("Automations")
                } footer: {
                    Text("Set up a Shortcuts automation that logs tap-to-pay purchases from Apple Wallet.")
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
            .navigationTitle("Settings")
            .sheet(item: $budgetToUnlock) { budget in
                EncryptionPasswordSheet(budget: budget, budgetStore: budgetStore)
            }
            .overlay {
                if budgetStore.isLoading {
                    ProgressView()
                }
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
                Text("Discards the local sync marker and re-adopts the server's view of your budget. Any transactions or edits made since the last successful sync may need to be re-entered.")
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
