import SwiftUI

struct ConnectionDataSettingsView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    var body: some View {
        Form {
            ServerConnectionSettingsSection()

            // Budget selection needs a live server session. Sync and backups
            // remain reachable for any loaded budget, including demo and
            // offline budgets without a session.
            if budgetStore.isConnected {
                BudgetSelectionSettingsSection()
            }

            if budgetStore.currentBudgetId != nil {
                SyncSettingsSection()
                BackupSettingsSection()
            }
        }
        .readableWidth()
        .navigationTitle("Connection & Data")
        .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.horizontal, 6, for: .scrollContent)
    }
}

private struct ServerConnectionSettingsSection: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var showingDisconnectConfirm = false
    @State private var editingServerConnection = false
    @State private var savingServerConnection = false
    @State private var editedServerURL = ""
    @State private var editedFallbackServerURL = ""
    @FocusState private var passwordFocused: Bool

    private func beginEditingServerConnection() {
        editedServerURL = budgetStore.serverURL
        editedFallbackServerURL = budgetStore.fallbackServerURL
        editingServerConnection = true
    }

    private func saveServerConnection() {
        savingServerConnection = true
        Task {
            let saved = await budgetStore.updateServerConnection(
                serverURL: editedServerURL,
                fallbackServerURL: editedFallbackServerURL
            )
            savingServerConnection = false
            if saved { editingServerConnection = false }
        }
    }

    private var serverConnectionHeader: some View {
        HStack {
            Text("Connection")
            Spacer()
            if budgetStore.isConnected {
                if editingServerConnection {
                    Button("Cancel", role: .cancel) {
                        editingServerConnection = false
                    }
                    .disabled(savingServerConnection)
                    Divider()
                        .frame(height: 16)
                    Button("Save") { saveServerConnection() }
                        .disabled(
                            editedServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || budgetStore.isLoading
                                || savingServerConnection
                        )
                } else {
                    Button("Edit") { beginEditingServerConnection() }
                }
            }
        }
        .font(.body)
        .textCase(nil)
    }

    @ViewBuilder
    private func serverURLFields(
        serverURL: Binding<String>,
        fallbackServerURL: Binding<String>
    ) -> some View {
        TextField("Server URL", text: serverURL)
            .textContentType(.URL)
            .autocapitalization(.none)
            .keyboardType(.URL)
            .accessibilityHint("Example: https://actual.example.com")

        TextField("Fallback server URL (optional)", text: fallbackServerURL)
            .textContentType(.URL)
            .autocapitalization(.none)
            .keyboardType(.URL)
            .accessibilityHint("Used when the primary server cannot be reached")
    }

    var body: some View {
        Section {
            if budgetStore.isConnected {
                if editingServerConnection {
                    serverURLFields(
                        serverURL: $editedServerURL,
                        fallbackServerURL: $editedFallbackServerURL
                    )
                } else {
                    LabeledContent("Server URL", value: budgetStore.serverURL)
                    LabeledContent(
                        "Fallback Server URL",
                        value: budgetStore.fallbackServerURL.isEmpty
                            ? "None"
                            : budgetStore.fallbackServerURL
                    )
                }
            } else {
                serverURLFields(
                    serverURL: $budgetStore.serverURL,
                    fallbackServerURL: $budgetStore.fallbackServerURL
                )
            }

            if budgetStore.isConnected {
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
            } else {
                // Show the password field before probing, when password
                // login is active, or when the first OpenID sign-in needs
                // the server password (no owner yet).
                if budgetStore.availableLoginMethods.isEmpty
                    || budgetStore.passwordLoginActive
                    || budgetStore.requiresServerPassword {
                    let placeholder = budgetStore.requiresServerPassword && !budgetStore.passwordLoginActive
                        ? "Server password (first sign-in)"
                        : "Password"
                    HStack {
                        if isPasswordVisible {
                            TextField(placeholder, text: $password)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .focused($passwordFocused)
                        } else {
                            SecureField(placeholder, text: $password)
                                .focused($passwordFocused)
                        }
                        Button {
                            isPasswordVisible.toggle()
                            // Swapping SecureField for TextField makes a new
                            // view, so the keyboard drops unless focus is
                            // re-asked for after SwiftUI installs the new one
                            // — same tick is too early.
                            Task { passwordFocused = true }
                        } label: {
                            Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
                    }
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
                    .disabled(
                        budgetStore.isLoading
                            || (budgetStore.requiresServerPassword && password.isEmpty)
                    )
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
            }
        } header: {
            serverConnectionHeader
        } footer: {
            if !budgetStore.isConnected {
                Text("Example: https://actual.example.com\n\nBehind an auth proxy like Cloudflare Access? Add a service token under \u{201C}Custom HTTP headers.\u{201D}\n\nNo server? Tap \u{201C}Try the demo budget\u{201D} to explore the app with sample data. The demo runs entirely on this device \u{2014} it never connects to a server or touches a real budget.")
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
        // Re-hide before iOS snapshots the screen for the app switcher, so a
        // revealed password doesn't land in that on-disk snapshot.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active { isPasswordVisible = false }
        }
        .onChange(of: budgetStore.isConnected) { _, isConnected in
            if !isConnected { editingServerConnection = false }
        }
    }
}

private struct BudgetSelectionSettingsSection: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @State private var budgetToUnlock: BudgetStore.RemoteBudget?
    @State private var showingBudgetSelectPrompt = false
    @State private var budgetToRemoveLocally: BudgetStore.RemoteBudget?
    @State private var budgetToDeleteFromServer: BudgetStore.RemoteBudget?
    @State private var showingCreateBudgetPrompt = false
    @State private var showingBudgetPicker = false
    @State private var newBudgetName = ""

    /// The open budget's server fileId — currentBudgetId is the internal id,
    /// so map through the local metadata.
    private func currentCloudFileId(in locals: [BudgetMetadata]) -> String? {
        guard let budgetId = budgetStore.currentBudgetId else { return nil }
        return locals.first { $0.id == budgetId }?.cloudFileId
    }

    /// The open budget when the server list doesn't include it (still loading,
    /// or the file was deleted from another client). It keeps a row so the
    /// selection stays visible and the local copy stays removable.
    private func unlistedCurrentBudget(in locals: [BudgetMetadata]) -> BudgetStore.RemoteBudget? {
        guard let budgetId = budgetStore.currentBudgetId,
              let metadata = locals.first(where: { $0.id == budgetId }),
              let fileId = metadata.cloudFileId,
              !budgetStore.remoteBudgets.contains(where: { $0.id == fileId })
        else { return nil }
        return BudgetStore.RemoteBudget(
            id: fileId,
            name: metadata.budgetName ?? "Unknown",
            groupId: metadata.groupId,
            isEncrypted: metadata.encryptKeyId != nil
        )
    }

    private func selectedBudget(in locals: [BudgetMetadata]) -> BudgetStore.RemoteBudget? {
        guard let cloudFileId = currentCloudFileId(in: locals) else { return nil }
        if let budget = budgetStore.remoteBudgets.first(where: { $0.id == cloudFileId }) {
            return budget
        }
        return unlistedCurrentBudget(in: locals)
    }

    var body: some View {
        // One directory read per render; every row check below shares it.
        let localBudgets = BudgetFileManager.shared.listLocalBudgets()

        Section {
            if let selectedBudget = selectedBudget(in: localBudgets) {
                selectedBudgetRow(selectedBudget, locals: localBudgets)
            } else {
                budgetPickerForNoSelection()
            }

            if budgetStore.remoteBudgets.isEmpty && !budgetStore.isLoading {
                Button("Refresh Budgets") {
                    Task { await budgetStore.fetchRemoteBudgets() }
                }
            }

            Button("Create New Budget") {
                newBudgetName = ""
                showingCreateBudgetPrompt = true
            }
            .disabled(budgetStore.isLoading || budgetStore.downloadingBudgetId != nil)
        } header: {
            Text("Budget Selection")
        } footer: {
            if budgetStore.currentBudgetId == nil {
                if budgetStore.remoteBudgets.isEmpty && !budgetStore.isLoading {
                    Text("No budgets were found on your server. Tap Create New Budget to make one, or Refresh Budgets if you've created one elsewhere.")
                } else {
                    Text("Select a budget to load it onto this device.")
                }
            } else if !budgetStore.remoteBudgets.isEmpty {
                Text("Tap the selected budget to switch budgets. Touch and hold it for options to remove it from this device or delete it from the server.")
            }
        }
        .alert("New Budget", isPresented: $showingCreateBudgetPrompt) {
            TextField("Name", text: $newBudgetName)
            Button("Create") {
                Task { await budgetStore.createBudget(named: newBudgetName) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates an empty budget file on your server and opens it on this device.")
        }
        .sheet(item: $budgetToUnlock) { budget in
            EncryptionPasswordSheet(budget: budget, budgetStore: budgetStore)
        }
        .sheet(item: $budgetToDeleteFromServer) { budget in
            DeleteServerBudgetSheet(budget: budget, budgetStore: budgetStore)
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
        .confirmationDialog(
            "Remove from this device?",
            isPresented: Binding(
                get: { budgetToRemoveLocally != nil },
                set: { if !$0 { budgetToRemoveLocally = nil } }
            ),
            titleVisibility: .visible,
            presenting: budgetToRemoveLocally
        ) { budget in
            Button("Remove from This Device", role: .destructive) {
                Task { await budgetStore.removeLocalBudget(cloudFileId: budget.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { budget in
            Text("Removes “\(budget.name)” from this device, including its local backups. Any changes that haven't synced to the server yet will be lost. The budget stays on your server and can be downloaded again.")
        }
        .task {
            await budgetStore.fetchRemoteBudgets()
            promptBudgetSelectionIfNeeded()
        }
    }

    private func selectedBudgetRow(
        _ budget: BudgetStore.RemoteBudget,
        locals: [BudgetMetadata]
    ) -> some View {
        let hasLocalCopy = locals.contains { $0.cloudFileId == budget.id }

        return Button {
            showingBudgetPicker = true
        } label: {
            HStack {
                if budget.isEncrypted {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                }

                Text(budget.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                if budgetStore.downloadingBudgetId == budget.id {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(budgetStore.downloadingBudgetId != nil)
        .accessibilityIdentifier("budget-selection-selected")
        .contextMenu {
            if hasLocalCopy {
                Button("Remove from This Device", systemImage: "iphone.slash") {
                    budgetToRemoveLocally = budget
                }
            }

            Button("Delete from Server…", systemImage: "trash", role: .destructive) {
                budgetToDeleteFromServer = budget
            }
        }
        .popover(isPresented: $showingBudgetPicker) {
            let otherBudgets = budgetStore.remoteBudgets.filter { $0.id != selectedBudget.id }
            let unlistedBudget = unlistedCurrentBudget(in: locals)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(otherBudgets) { otherBudget in
                        Button {
                            showingBudgetPicker = false
                            openBudget(otherBudget)
                        } label: {
                            HStack {
                                if otherBudget.isEncrypted {
                                    Image(systemName: "lock.fill")
                                        .foregroundStyle(.secondary)
                                }

                                Text(otherBudget.name)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if let unlistedBudget,
                       unlistedBudget.id != selectedBudget.id {
                        Button {
                            showingBudgetPicker = false
                            openBudget(unlistedBudget)
                        } label: {
                            HStack {
                                if unlistedBudget.isEncrypted {
                                    Image(systemName: "lock.fill")
                                        .foregroundStyle(.secondary)
                                }

                                Text(unlistedBudget.name)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if otherBudgets.isEmpty && unlistedBudget == nil {
                        Text("No other budgets")
                            .foregroundStyle(.secondary)
                            .padding(16)
                    }
                }
            }
            .frame(minWidth: 240, maxHeight: 320)
            .padding(.vertical, 8)
            .presentationCompactAdaptation(.popover)
            .accessibilityIdentifier("budget-selection-picker")
        }
    }

    private func budgetPickerForNoSelection() -> some View {
        Menu {
            ForEach(budgetStore.remoteBudgets) { budget in
                Button {
                    openBudget(budget)
                } label: {
                    HStack {
                        if budget.isEncrypted {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                        }

                        Text(budget.name)
                    }
                }
            }
        } label: {
            HStack {
                Text("Select a Budget")
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(budgetStore.downloadingBudgetId != nil || budgetStore.remoteBudgets.isEmpty)
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
}

private struct DeleteServerBudgetSheet: View {
    let budget: BudgetStore.RemoteBudget
    @ObservedObject var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    @State private var typedName = ""
    @State private var errorText: String?
    @State private var isWorking = false

    private var nameMatches: Bool {
        typedName.trimmingCharacters(in: .whitespacesAndNewlines) == budget.name
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Budget name", text: $typedName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(isWorking)
                } header: {
                    Text("Delete from Server")
                } footer: {
                    Text("This permanently deletes “\(budget.name)” from your Actual server for every device that uses it, along with this device's copy and its local backups. This cannot be undone.\n\nType the budget's name to confirm.")
                }

                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.callout)
                }
            }
            .navigationTitle("Delete Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Delete", role: .destructive) { Task { await deleteBudget() } }
                        .disabled(!nameMatches || isWorking)
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
    }

    private func deleteBudget() async {
        isWorking = true
        errorText = nil
        let failure = await budgetStore.deleteServerBudget(budget)
        isWorking = false
        if let failure {
            errorText = failure
        } else {
            dismiss()
        }
    }
}

private struct SyncSettingsSection: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastBackgroundRefresh = BackgroundRefreshStatus().lastRun
    @State private var refreshRequestError = BackgroundRefreshStatus().lastScheduleError
    @State private var showingResetSyncConfirm = false

    var body: some View {
        Section("Sync") {
            HStack {
                Text("Status")
                Spacer()
                switch budgetStore.syncState {
                case .idle:
                    Text("Idle").foregroundStyle(.secondary)
                case .syncing:
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.7)
                        Text("Syncing...").foregroundStyle(.secondary)
                    }
                case .offline:
                    Text("Offline").foregroundStyle(.orange)
                case .error:
                    Text("Error").foregroundStyle(.red)
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
                    Text("Never").foregroundStyle(.secondary)
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
                Task { await budgetStore.sync() }
            }
            .disabled(budgetStore.syncState == .syncing)

            if case .error = budgetStore.syncState {
                Button("Reset Sync State", role: .destructive) {
                    showingResetSyncConfirm = true
                }
                .disabled(budgetStore.syncState == .syncing)
            }
        }
        .task { reloadBackgroundRefreshStatus() }
        // The background refresh task fires while the app is suspended —
        // same process, so the @State snapshot taken at launch never
        // re-reads on its own and would show "Never" indefinitely.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                reloadBackgroundRefreshStatus()
            }
        }
        .confirmationDialog(
            "Reset sync state?",
            isPresented: $showingResetSyncConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset & Resync", role: .destructive) {
                Task { await budgetStore.resetSyncState() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Discards the local sync marker and re-checks your budget against the server, pulling down anything missing. Local edits are re-sent rather than discarded, but a large budget can take a moment to reconcile.")
        }
    }

    private func reloadBackgroundRefreshStatus() {
        let status = BackgroundRefreshStatus()
        lastBackgroundRefresh = status.lastRun
        refreshRequestError = status.lastScheduleError
    }
}

private struct BackupSettingsSection: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @State private var confirmBackupOverBaseline = false

    var body: some View {
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
        } header: {
            Text("Backups")
        } footer: {
            // No cadence promise — iOS can't run a 15-minute
            // background timer (plan D2).
            Text("Backups are stored on this device. One is taken automatically when you leave the app.")
        }
        .task { await budgetStore.refreshBackups() }
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
    }
}
