import AppIntents
import Testing
@testable import Actuali

struct LogTransactionIntentTests {
    @Test func detachedCloudBudgetCannotBeSelectedForShortcutWrites() {
        let localOnly = BudgetMetadata(
            id: "local-budget",
            budgetName: "Local",
            cloudFileId: nil,
            groupId: nil,
            resetClock: nil,
            lastUploaded: nil,
            encryptKeyId: nil
        )
        let detachedCloudCopy = BudgetMetadata(
            id: "restored-budget",
            budgetName: "Restored",
            cloudFileId: "cloud-file",
            groupId: nil,
            resetClock: nil,
            lastUploaded: nil,
            encryptKeyId: nil
        )
        let connectedCloudBudget = BudgetMetadata(
            id: "connected-budget",
            budgetName: "Connected",
            cloudFileId: "cloud-file",
            groupId: "sync-group",
            resetClock: nil,
            lastUploaded: nil,
            encryptKeyId: nil
        )

        #expect(localOnly.canWriteToLocally)
        #expect(!detachedCloudCopy.canWriteToLocally)
        #expect(connectedCloudBudget.canWriteToLocally)
    }

    @MainActor @Test func savedLocalBudgetEntityNeedsNoRemoteFetch() {
        let local = BudgetMetadata(
            id: "local-budget", budgetName: "Offline", cloudFileId: "cloud-file",
            groupId: "sync-group", resetClock: nil, lastUploaded: nil, encryptKeyId: nil
        )
        let entries = BudgetEntity.availableEntities(
            localBudgets: [local], remoteBudgets: [], isConnected: true
        )
        #expect(!BudgetEntityQuery.needsRemoteFetch(
            identifiers: ["cloud-file"], entities: entries,
            isConnected: true
        ))
        #expect(BudgetEntityQuery.needsRemoteFetch(
            identifiers: ["server-only-file"], entities: entries,
            isConnected: true
        ))
        #expect(!BudgetEntityQuery.needsRemoteFetch(
            identifiers: ["server-only-file"], entities: entries,
            isConnected: false
        ))
    }

    @MainActor @Test func encryptedBudgetWithoutKeyCannotBeOpenedFromRecovery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = BudgetFileManager(rootDirectoryForTesting: root)
        let budgetID = "encrypted-recovery"
        let fileID = UUID().uuidString
        try FileManager.default.createDirectory(
            at: manager.budgetDirectory(for: budgetID), withIntermediateDirectories: true
        )
        try Data().write(to: manager.databasePath(for: budgetID))
        try JSONEncoder().encode(BudgetMetadata(
            id: budgetID, budgetName: "Locked", cloudFileId: fileID,
            groupId: "sync-group", resetClock: nil, lastUploaded: nil,
            encryptKeyId: "missing-encryption-key"
        )).write(to: manager.metadataPath(for: budgetID))
        let store = BudgetStore.previewInstance()
        store.setFileManagerForTesting(manager)

        #expect(store.nameForShortcutRecoveryBudget(budgetID) == nil)
        let switched = await store.switchToShortcutRecoveryBudget(budgetID)
        #expect(!switched)
        #expect(store.currentBudgetId == nil)
        await #expect(throws: TransactionLogger.LoggerError.noBudgetLoaded) {
            try await store.localBudgetIDForIntent(budgetID)
        }
    }

    @MainActor @Test func shortcutWriterRefusesBudgetWhileBackupRestoreIsReplacingFiles() async {
        let store = BudgetStore.previewInstance()
        store.setBudgetFileReplacementInProgressForTesting("restoring-budget", inProgress: true)

        await #expect(throws: TransactionLogger.LoggerError.noBudgetLoaded) {
            try await store.transactionWriter(for: "restoring-budget")
        }
    }

    @MainActor @Test func shortcutCannotReplaceDetachedRestoredBudgetWithServerCopy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileManager = BudgetFileManager(rootDirectoryForTesting: root)
        let localBudgetID = "restored-local-id"
        try FileManager.default.createDirectory(
            at: fileManager.budgetDirectory(for: localBudgetID),
            withIntermediateDirectories: true
        )
        let originalDatabase = Data("restored-data".utf8)
        try originalDatabase.write(to: fileManager.databasePath(for: localBudgetID))
        try JSONEncoder().encode(BudgetMetadata(
            id: localBudgetID,
            budgetName: "Restored",
            cloudFileId: "restored-cloud-id",
            groupId: nil,
            resetClock: nil,
            lastUploaded: nil,
            encryptKeyId: nil
        )).write(to: fileManager.metadataPath(for: localBudgetID))

        let store = BudgetStore.previewInstance()
        store.setFileManagerForTesting(fileManager)
        let defaultsName = "ActualiTests-DetachedRestore-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        store.configureAppleWalletLinksForTesting(
            defaults: defaults, budgetId: "a-different-active-budget"
        )

        await #expect(throws: TransactionLogger.LoggerError.noBudgetLoaded) {
            try await store.localBudgetIDForIntent("restored-cloud-id")
        }
        #expect(try Data(contentsOf: fileManager.databasePath(for: localBudgetID)) == originalDatabase)
    }

    @MainActor @Test func shortcutBudgetEntitiesMergeServerBudgetsWithoutDuplicates() {
        let localBudgets = [
            BudgetMetadata(
                id: "personal-local",
                budgetName: "Old Personal Name",
                cloudFileId: "personal-file",
                groupId: "personal-group",
                resetClock: nil,
                lastUploaded: nil,
                encryptKeyId: nil
            ),
            BudgetMetadata(
                id: "personal-duplicate",
                budgetName: "Personal",
                cloudFileId: "personal-file",
                groupId: "personal-group",
                resetClock: nil,
                lastUploaded: nil,
                encryptKeyId: nil
            ),
            BudgetMetadata(
                id: DemoDataSeeder.budgetId,
                budgetName: "Demo Budget",
                cloudFileId: nil,
                groupId: nil,
                resetClock: nil,
                lastUploaded: nil,
                encryptKeyId: nil
            ),
            BudgetMetadata(
                id: "local-only",
                budgetName: "Offline",
                cloudFileId: nil,
                groupId: nil,
                resetClock: nil,
                lastUploaded: nil,
                encryptKeyId: nil
            ),
            BudgetMetadata(
                id: "restored-local",
                budgetName: "Restored Personal",
                cloudFileId: "restored-file",
                groupId: nil,
                resetClock: nil,
                lastUploaded: nil,
                encryptKeyId: nil
            ),
        ]
        let remoteBudgets = [
            BudgetStore.RemoteBudget(
                id: "personal-file", name: "Personal", groupId: "personal-group", isEncrypted: false
            ),
            BudgetStore.RemoteBudget(
                id: "business-file", name: "Business", groupId: "business-group", isEncrypted: false
            ),
            BudgetStore.RemoteBudget(
                id: "encrypted-file", name: "Encrypted", groupId: "encrypted-group", isEncrypted: true
            ),
            BudgetStore.RemoteBudget(
                id: "restored-file", name: "Restored Personal", groupId: "restored-group", isEncrypted: false
            ),
            BudgetStore.RemoteBudget(
                id: "missing-group", name: "Detached", groupId: nil, isEncrypted: false
            ),
            BudgetStore.RemoteBudget(
                id: "business-file", name: "Business", groupId: "business-group", isEncrypted: false
            ),
        ]

        let connected = BudgetEntity.availableEntities(
            localBudgets: localBudgets,
            remoteBudgets: remoteBudgets,
            isConnected: true
        )
        #expect(Set(connected.map(\.id)) == [
            "personal-file", "business-file", "encrypted-file", "local-only",
        ])
        #expect(connected.filter { $0.id == "personal-file" }.count == 1)
        #expect(connected.first(where: { $0.id == "personal-file" })?.name == "Personal")
        #expect(!connected.contains(where: { $0.name == "Demo Budget" }))
        #expect(!connected.contains(where: { $0.id == "missing-group" }))
        #expect(!connected.contains(where: { $0.id == "restored-file" }))

        let offline = BudgetEntity.availableEntities(
            localBudgets: localBudgets,
            remoteBudgets: remoteBudgets,
            isConnected: false
        )
        #expect(offline.contains(where: { $0.id == DemoDataSeeder.budgetId }))
        #expect(!offline.contains(where: { $0.id == "business-file" }))
    }

    @MainActor @Test func failureNotificationMapsCloudBudgetIDToLocalScopedIDs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileManager = BudgetFileManager(rootDirectoryForTesting: root)
        let localBudgetID = "personal-local-id"
        try FileManager.default.createDirectory(
            at: fileManager.budgetDirectory(for: localBudgetID),
            withIntermediateDirectories: true
        )
        try Data().write(to: fileManager.databasePath(for: localBudgetID))
        try JSONEncoder().encode(BudgetMetadata(
            id: localBudgetID,
            budgetName: "Personal",
            cloudFileId: "personal-cloud-id",
            groupId: "personal-group",
            resetClock: nil,
            lastUploaded: nil,
            encryptKeyId: nil
        )).write(to: fileManager.metadataPath(for: localBudgetID))

        let store = BudgetStore.previewInstance()
        store.setFileManagerForTesting(fileManager)

        let targetBudgetID = try #require(
            await store.localBudgetIDForFailureNotification("personal-cloud-id")
        )
        let accountID = AccountEntity.scopedID(
            budgetID: localBudgetID,
            accountID: "checking-account"
        )
        let categoryID = CategoryEntity.scopedID(
            budgetID: localBudgetID,
            categoryID: "groceries"
        )

        #expect(ScopedEntityID.rowID(
            accountID,
            budgetID: targetBudgetID,
            allowLegacyID: false
        ) == "checking-account")
        #expect(ScopedEntityID.rowID(
            categoryID,
            budgetID: targetBudgetID,
            allowLegacyID: false
        ) == "groceries")
    }

    @Test func accountIdentifiersCannotCrossBudgets() {
        let saved = AccountEntity.scopedID(budgetID: "budget-a", accountID: "checking")
        #expect(ScopedEntityID.rowID(
            saved, budgetID: "budget-a", allowLegacyID: false
        ) == "checking")
        #expect(ScopedEntityID.rowID(
            saved, budgetID: "budget-b", allowLegacyID: false
        ) == nil)
        #expect(ScopedEntityID.rowID(
            "checking", budgetID: "budget-a", allowLegacyID: false
        ) == nil)
        #expect(ScopedEntityID.rowID(
            "checking", budgetID: "budget-a", allowLegacyID: true
        ) == "checking")
    }

    @Test func scopedIDsResolveOnlyInTheirOwnBudget() {
        #expect(ScopedEntityID.rowID(
            "cloud-file|checking", budgetID: "cloud-file",
            allowLegacyID: false
        ) == "checking")
        #expect(ScopedEntityID.rowID(
            "local-budget|checking", budgetID: "cloud-file",
            allowLegacyID: false
        ) == nil)
        #expect(ScopedEntityID.rowID(
            "other-budget|checking", budgetID: "cloud-file",
            allowLegacyID: false
        ) == nil)
        #expect(ScopedEntityID.rowID(
            "checking", budgetID: "cloud-file",
            allowLegacyID: false
        ) == nil)
        #expect(ScopedEntityID.rowID(
            "checking", budgetID: "cloud-file",
            allowLegacyID: true
        ) == "checking")
        #expect(ScopedEntityID.make(budgetID: "cloud-file", rowID: "groceries")
            == "cloud-file|groceries")
    }

    @Test func categoryIdentifiersCannotCrossBudgets() {
        let saved = CategoryEntity.scopedID(budgetID: "budget-a", categoryID: "groceries")
        #expect(ScopedEntityID.rowID(
            saved, budgetID: "budget-a", allowLegacyID: false
        ) == "groceries")
        #expect(ScopedEntityID.rowID(
            saved, budgetID: "budget-b", allowLegacyID: false
        ) == nil)
        #expect(ScopedEntityID.rowID(
            "groceries", budgetID: "budget-a", allowLegacyID: false
        ) == nil)
        #expect(ScopedEntityID.rowID(
            "groceries", budgetID: "budget-a", allowLegacyID: true
        ) == "groceries")
    }

    @Test func failureNotificationRetainsTargetBudgetAndRejectsWrongActiveBudget() throws {
        let prefill = TransactionPrefill(
            accountId: nil,
            payee: "Shop",
            amountCents: -650,
            budgetId: "travel-budget",
            date: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let decoded = try #require(TransactionPrefill(userInfo: prefill.userInfo))
        #expect(decoded.budgetId == "travel-budget")
        #expect(!decoded.canOpen(in: "home-budget"))
        #expect(decoded.canOpen(in: "travel-budget"))
        #expect(TransactionPrefill(userInfo: [
            "kind": "com.mfazz.Actuali.transactionPrefill",
            "date": 1_750_000_000.0,
        ])?.canOpen(in: "home-budget") == true)
    }

    @Test func recoveryGuardRequiresTheRightBudget() {
        let prefill = TransactionPrefill(
            accountId: "checking", payee: "Coffee", amountCents: -500,
            budgetId: "budget-b", date: Date()
        )
        #expect(!prefill.canOpen(in: "budget-a"))
        #expect(prefill.canOpen(in: "budget-b"))
    }

    @Test func failureNotificationDoesNotPrefillIDsFromAnotherBudget() {
        let otherBudget = LogTransactionIntent.failurePrefillIDs(
            targetBudgetId: "budget-b",
            activeBudgetId: "budget-a",
            accountEntityId: AccountEntity.scopedID(
                budgetID: "budget-b", accountID: "checking"
            ),
            categoryEntityId: CategoryEntity.scopedID(
                budgetID: "budget-b", categoryID: "groceries"
            ),
            availableAccountIDs: ["checking"],
            availableCategoryIDs: ["groceries"],
            allowLegacyIDs: false
        )
        #expect(otherBudget.accountId == nil)
        #expect(otherBudget.categoryId == nil)

        // A notification for a deliberately selected inactive budget may
        // retain validated IDs because the recovery sheet requires switching.
        let inactiveRecovery = LogTransactionIntent.failurePrefillIDs(
            targetBudgetId: "budget-b",
            activeBudgetId: "budget-a",
            accountEntityId: AccountEntity.scopedID(
                budgetID: "budget-b", accountID: "checking"
            ),
            categoryEntityId: CategoryEntity.scopedID(
                budgetID: "budget-b", categoryID: "groceries"
            ),
            availableAccountIDs: ["checking"],
            availableCategoryIDs: ["groceries"],
            allowLegacyIDs: false,
            allowInactiveBudget: true
        )
        #expect(inactiveRecovery.accountId == "checking")
        #expect(inactiveRecovery.categoryId == "groceries")

        let activeBudget = LogTransactionIntent.failurePrefillIDs(
            targetBudgetId: "budget-a",
            activeBudgetId: "budget-a",
            accountEntityId: AccountEntity.scopedID(
                budgetID: "budget-a", accountID: "checking"
            ),
            categoryEntityId: CategoryEntity.scopedID(
                budgetID: "budget-a", categoryID: "groceries"
            ),
            availableAccountIDs: ["checking"],
            availableCategoryIDs: ["groceries"],
            allowLegacyIDs: false
        )
        #expect(activeBudget.accountId == "checking")
        #expect(activeBudget.categoryId == "groceries")

        let syncedBudget = LogTransactionIntent.failurePrefillIDs(
            targetBudgetId: "local-budget-id",
            activeBudgetId: "local-budget-id",
            entityBudgetId: "cloud-file-id",
            accountEntityId: AccountEntity.scopedID(
                budgetID: "cloud-file-id", accountID: "checking"
            ),
            categoryEntityId: CategoryEntity.scopedID(
                budgetID: "cloud-file-id", categoryID: "groceries"
            ),
            availableAccountIDs: ["checking"],
            availableCategoryIDs: ["groceries"],
            allowLegacyIDs: false
        )
        #expect(syncedBudget.accountId == "checking")
        #expect(syncedBudget.categoryId == "groceries")
    }

    @Test func inactiveOfflineBudgetNotificationDoesNotPromiseAutomaticSync() {
        let body = TransactionLogNotifier.composeSuccessBody(
            payee: "Coffee",
            amountCents: -650,
            currencyCode: "USD",
            narrowSymbol: false,
            synced: false,
            locale: Locale(identifier: "en_US"),
            needsOpeningBudget: true
        )
        #expect(body.contains("select a budget"))
        #expect(!body.contains("will sync when you open Actuali"))
    }

    @Test func silentByDefaultSoAutomationsDoNotShowADialog() {
        let result = LogTransactionIntent.result(dialogText: "Logged $4.50 at Blue Bottle", showConfirmation: false)
        #expect(result.dialog == nil)
    }

    @Test func speaksWhenTheCallerAsksFor() {
        let result = LogTransactionIntent.result(dialogText: "Logged $4.50 at Blue Bottle", showConfirmation: true)
        #expect(result.dialog != nil)
    }

    private var appBundle: Bundle {
        Bundle(identifier: "com.mfazz.ActualiOS")!
    }

    @Test func siriShortcutOptsIntoTheSpokenConfirmation() {
        #expect(LogTransactionIntent(showConfirmation: true).showConfirmation)
        #expect(LogTransactionIntent().showConfirmation == false)
    }

    @Test(arguments: [
        (Locale(identifier: "en_US"), "Amount must be greater than 0 (received \"12\").", "Couldn't save transaction. Tap to retry. (disk full)"),
        (Locale(identifier: "fr_FR"), "Le montant doit être supérieur à 0 (valeur reçue : \"12\").", "Impossible d'enregistrer la transaction. Touchez pour réessayer. (disk full)"),
        (Locale(identifier: "pt_BR"), "O valor deve ser maior que 0 (valor recebido: \"12\").", "Não foi possível salvar a transação. Toque para tentar novamente. (disk full)"),
    ])
    func errorsUseRequestedLocaleAndTypedDetails(locale: Locale, invalidAmount: String, writeFailed: String) {
        #expect(LogTransactionError.localizedString(
            for: .invalidAmount(received: " 12 "), locale: locale, bundle: appBundle
        ) == invalidAmount)
        #expect(LogTransactionError.localizedString(
            for: .writeFailed(underlying: "disk full"), locale: locale, bundle: appBundle
        ) == writeFailed)
    }

    @Test func errorDescriptionMatchesTheLocalizedResource() {
        let error = LogTransactionError.invalidAmount(received: "12")
        #expect(error.errorDescription == String(localized: error.localizedStringResource))
    }

    @MainActor @Test func loggerErrorsRemainTypedUntilPresentation() {
        let locale = Locale(identifier: "fr_FR")
        let mapped = LogTransactionError.wrapping(
            TransactionLogger.LoggerError.transactionSuppressedByRule
        )

        guard case .transactionSuppressedByRule = mapped else {
            Issue.record("Expected a typed suppressed-by-rule error")
            return
        }
        #expect(LogTransactionError.localizedString(
            for: mapped, locale: locale, bundle: appBundle
        ) == "Une règle de transaction a ignoré cette transaction.")
        #expect(TransactionLogger.LoggerError.transactionAlreadyExists.message(
            locale: locale, bundle: appBundle
        ) == "Cette transaction a déjà été enregistrée.")
    }

    @Test(arguments: [
        (Locale(identifier: "en_US"), "Account was not found. Select a valid account in your shortcut."),
        (Locale(identifier: "fr_FR"), "Compte introuvable. Sélectionnez un compte valide dans votre raccourci."),
        (Locale(identifier: "pt_BR"), "A conta não foi encontrada. Selecione uma conta válida no atalho."),
    ])
    func balanceErrorsUseRequestedLocale(locale: Locale, value: String) {
        #expect(GetBalanceError.localizedString(for: .accountNotFound, locale: locale, bundle: appBundle) == value)
    }

    @Test(arguments: [
        ("en_US", true, "AMOUNT", "PAYEE", "Logged AMOUNT at PAYEE"),
        ("fr_FR", true, "AMOUNT", "PAYEE", "Transaction de AMOUNT chez PAYEE enregistrée"),
        ("pt_BR", true, "AMOUNT", "PAYEE", "Transação de AMOUNT em PAYEE registrada"),
        ("en_US", false, "AMOUNT", "PAYEE", "Saved locally: AMOUNT at PAYEE"),
        ("fr_FR", false, "AMOUNT", "PAYEE", "Enregistrée localement : AMOUNT chez PAYEE"),
        ("pt_BR", false, "AMOUNT", "PAYEE", "Salva localmente: AMOUNT em PAYEE"),
        ("en_US", true, "AMOUNT", "", "Logged AMOUNT"),
        ("fr_FR", false, "AMOUNT", "", "Enregistrée localement : AMOUNT"),
    ])
    func dialogFormatterPreservesAmountThenPayeePlaceholderOrder(
        localeIdentifier: String, synced: Bool, amount: String, payee: String, expected: String
    ) {
        #expect(LogTransactionDialogFormatter.string(
            amount: amount,
            payee: payee,
            synced: synced,
            locale: Locale(identifier: localeIdentifier),
            bundle: appBundle
        ) == expected)
    }
}
