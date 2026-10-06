import CoreTransferable
import Darwin
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DiagnosticSettingsSnapshot: Sendable, Equatable {
    let appearanceMode: String
    let startTab: String
    let defaultDashboardConfigured: Bool
    let currencyCode: String
    let numberFormat: String
    let useNarrowCurrencySymbol: Bool

    let budgetDisplayStyle: String
    let showCompactBudgetOverview: Bool
    let showBudgetedAmounts: Bool
    let showCompactSpentColumn: Bool
    let showGroupTotals: Bool
    let showBudgetCheckInStrip: Bool
    let hideZeroBudgetCategories: Bool
    let showHiddenCategories: Bool
    let showCategoryStatusDots: Bool
    let customCategoryStatusColorCount: Int
    let showBudgetProgressBars: Bool
    let showInverseBudgetProgressBars: Bool
    let hiddenBudgetProgressCategoryCount: Int
    let spentCategoryExclusionCount: Int
    let showOverspentBadge: Bool
    let hideIncomeGroup: Bool
    let goalTemplatesEnabled: Bool
    let goalTemplatesUIEnabled: Bool

    let transactionDisplayMode: String
    let transactionStatusFilter: String
    let showTransactionStatusFilters: Bool
    let uncategorizedTapAction: String
    let conventionalAmountEntry: Bool
    let defaultAccountConfigured: Bool
    let recordPayeeLocations: Bool
    let payeeLocationWritesSupported: Bool

    let hideBalances: Bool
    let shakeToHideBalances: Bool
    let hideDecimalPlaces: Bool
    let hideClosedAccounts: Bool

    let transactionNotificationsEnabled: Bool
    let creditCardDueNotificationsEnabled: Bool

    let cardAccountMappingCount: Int
    let creditCardConfigurationCount: Int
    let loanConfigurationCount: Int
    let depositConfigurationCount: Int
    let categoryFundingConfigured: Bool
    let categoryFundingEnabled: Bool
    let categoryFundingSource: String

    static let empty = DiagnosticSettingsSnapshot(
        appearanceMode: "unknown",
        startTab: "unknown",
        defaultDashboardConfigured: false,
        currencyCode: "unknown",
        numberFormat: "unknown",
        useNarrowCurrencySymbol: false,
        budgetDisplayStyle: "unknown",
        showCompactBudgetOverview: false,
        showBudgetedAmounts: false,
        showCompactSpentColumn: false,
        showGroupTotals: false,
        showBudgetCheckInStrip: false,
        hideZeroBudgetCategories: false,
        showHiddenCategories: false,
        showCategoryStatusDots: false,
        customCategoryStatusColorCount: 0,
        showBudgetProgressBars: false,
        showInverseBudgetProgressBars: false,
        hiddenBudgetProgressCategoryCount: 0,
        spentCategoryExclusionCount: 0,
        showOverspentBadge: false,
        hideIncomeGroup: false,
        goalTemplatesEnabled: false,
        goalTemplatesUIEnabled: false,
        transactionDisplayMode: "unknown",
        transactionStatusFilter: "unknown",
        showTransactionStatusFilters: false,
        uncategorizedTapAction: "unknown",
        conventionalAmountEntry: false,
        defaultAccountConfigured: false,
        recordPayeeLocations: false,
        payeeLocationWritesSupported: false,
        hideBalances: false,
        shakeToHideBalances: false,
        hideDecimalPlaces: false,
        hideClosedAccounts: false,
        transactionNotificationsEnabled: false,
        creditCardDueNotificationsEnabled: false,
        cardAccountMappingCount: 0,
        creditCardConfigurationCount: 0,
        loanConfigurationCount: 0,
        depositConfigurationCount: 0,
        categoryFundingConfigured: false,
        categoryFundingEnabled: false,
        categoryFundingSource: "none"
    )

    @MainActor
    static func capture(from budgetStore: BudgetStore) -> Self {
        let fundingConfiguration = CategoryFundingAutomation.loadConfiguration(
            for: budgetStore.currentBudgetId
        )

        let fundingSource: String = switch fundingConfiguration?.fundingSource {
        case .none:
            "none"
        case .some(.toBudget):
            "to-budget"
        case .some(.category):
            "category"
        }
        let visibleCategoryIDs = Set(
            budgetStore.categoryGroups.flatMap(\.categories).map(\.id)
        )

        return Self(
            appearanceMode: budgetStore.appearanceMode.rawValue,
            startTab: budgetStore.startTab.rawValue,
            defaultDashboardConfigured: budgetStore.defaultDashboardPageId != nil,
            currencyCode: budgetStore.currencyCode.isEmpty ? "none" : budgetStore.currencyCode,
            numberFormat: budgetStore.numberFormat.rawValue,
            useNarrowCurrencySymbol: budgetStore.useNarrowCurrencySymbol,
            budgetDisplayStyle: budgetStore.budgetDisplayStyle.rawValue,
            showCompactBudgetOverview: budgetStore.showCompactBudgetOverview,
            showBudgetedAmounts: budgetStore.showBudgetedAmounts,
            showCompactSpentColumn: budgetStore.showCompactSpentColumn,
            showGroupTotals: budgetStore.showGroupTotals,
            showBudgetCheckInStrip: budgetStore.showBudgetCheckInStrip,
            hideZeroBudgetCategories: budgetStore.hideZeroBudgetCategories,
            showHiddenCategories: budgetStore.showHiddenCategories,
            showCategoryStatusDots: budgetStore.showCategoryStatusDots,
            customCategoryStatusColorCount: CategoryProgressState.allCases.filter {
                budgetStore.hasCustomCategoryStatusDotColor(for: $0)
            }.count,
            showBudgetProgressBars: budgetStore.showBudgetProgressBars,
            showInverseBudgetProgressBars: budgetStore.showInverseBudgetProgressBars,
            hiddenBudgetProgressCategoryCount: budgetStore.hiddenBudgetProgressCategoryIDs
                .intersection(visibleCategoryIDs)
                .count,
            spentCategoryExclusionCount: budgetStore.excludedFromSpentCategoryIds.count,
            showOverspentBadge: budgetStore.showOverspentBadge,
            hideIncomeGroup: budgetStore.hideIncomeGroup,
            goalTemplatesEnabled: budgetStore.goalTemplatesEnabled,
            goalTemplatesUIEnabled: budgetStore.goalTemplatesUIEnabled,
            transactionDisplayMode: budgetStore.transactionDisplayMode.rawValue,
            transactionStatusFilter: budgetStore.transactionStatusFilter.rawValue,
            showTransactionStatusFilters: budgetStore.showTransactionStatusFilters,
            uncategorizedTapAction: budgetStore.uncategorizedTapAction.rawValue,
            conventionalAmountEntry: budgetStore.conventionalAmountEntry,
            defaultAccountConfigured: budgetStore.defaultAccountId != nil,
            recordPayeeLocations: budgetStore.recordPayeeLocations,
            payeeLocationWritesSupported: budgetStore.payeeLocationWritesEnabled,
            hideBalances: budgetStore.hideBalances,
            shakeToHideBalances: budgetStore.shakeToHideBalances,
            hideDecimalPlaces: budgetStore.hideDecimalPlaces,
            hideClosedAccounts: budgetStore.hideClosedAccounts,
            transactionNotificationsEnabled: TransactionNotificationSettings().isEnabled,
            creditCardDueNotificationsEnabled: CreditCardNotificationSettings().isEnabled,
            cardAccountMappingCount: budgetStore.cardAccountMappings.count,
            creditCardConfigurationCount: budgetStore.creditCardConfigs.count,
            loanConfigurationCount: budgetStore.loanConfigs.count,
            depositConfigurationCount: budgetStore.depositConfigs.count,
            categoryFundingConfigured: fundingConfiguration != nil,
            categoryFundingEnabled: fundingConfiguration?.isEnabled ?? false,
            categoryFundingSource: fundingSource
        )
    }
}

struct DiagnosticReport: Equatable, Sendable, Transferable {
    let text: String
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { report in
            Data(report.text.utf8)
        }
        .suggestedFileName { report in
            report.filename
        }
    }
}

struct DiagnosticReportEnvironment: Sendable, Equatable {
    let version: String
    let build: String
    let bundle: String
    let buildConfiguration: String
    let hardwareModel: String
    let operatingSystem: String
    let processorCount: Int
    let activeProcessorCount: Int
    let physicalMemoryBytes: UInt64
    let availableStorageBytes: Int64?

    static let empty = DiagnosticReportEnvironment(
        version: "Unknown",
        build: "Unknown",
        bundle: "Unknown",
        buildConfiguration: "Unknown",
        hardwareModel: "Unknown",
        operatingSystem: "Unknown",
        processorCount: 0,
        activeProcessorCount: 0,
        physicalMemoryBytes: 0,
        availableStorageBytes: nil
    )

    @MainActor
    static func capture() -> Self {
        let processInfo = ProcessInfo.processInfo
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Unknown"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "Unknown"
        let bundle = Bundle.main.bundleIdentifier ?? "Unknown"
        let availableStorage: Int64?
        if let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            availableStorage = try? applicationSupportURL.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage
        } else {
            availableStorage = nil
        }

        return DiagnosticReportEnvironment(
            version: version,
            build: build,
            bundle: bundle,
            buildConfiguration: buildConfiguration,
            hardwareModel: hardwareModel,
            operatingSystem: processInfo.operatingSystemVersionString,
            processorCount: processInfo.processorCount,
            activeProcessorCount: processInfo.activeProcessorCount,
            physicalMemoryBytes: processInfo.physicalMemory,
            availableStorageBytes: availableStorage
        )
    }

    private static var buildConfiguration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }

    private static var hardwareModel: String {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else {
            return "Unknown"
        }
        let machine = systemInfo.machine
        return withUnsafeBytes(of: machine) { bytes in
            guard let baseAddress = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return "Unknown"
            }
            return String(cString: baseAddress)
        }
    }
}

@MainActor
enum DiagnosticReportBuilder {
    // The report payload is a support-facing technical format; its field names
    // stay in English so support tooling and copied reports remain consistent.
    static func make(
        snapshot: DiagnosticLogSnapshot,
        settings: DiagnosticSettingsSnapshot,
        environment: DiagnosticReportEnvironment = .capture(),
        generatedAt: Date = Date()
    ) -> DiagnosticReport {
        let processInfo = ProcessInfo.processInfo
        let application = UIApplication.shared

        var lines: [String] = [
            "Actuali Diagnostic Report",
            "Generated: \(timestamp(generatedAt))",
            "Privacy: This report excludes credentials, custom header values, account and budget identifiers, server addresses, budget contents, transaction details, and financial amounts.",
            "",
            "[Application]",
            "Version: \(environment.version) (\(environment.build))",
            "Bundle: \(environment.bundle)",
            "Build configuration: \(environment.buildConfiguration)",
            "Process uptime seconds: \(Int(processInfo.systemUptime))",
            "",
            "[Device]",
            "Hardware model: \(environment.hardwareModel)",
            "Operating system: \(environment.operatingSystem)",
            "Processor count: \(environment.processorCount)",
            "Active processor count: \(environment.activeProcessorCount)",
            "Physical memory bytes: \(environment.physicalMemoryBytes)",
            "Low Power Mode: \(yesNo(processInfo.isLowPowerModeEnabled))",
            "Thermal state: \(thermalState(processInfo.thermalState))",
            "Application state: \(applicationState(application.applicationState))",
            "Protected data available: \(yesNo(application.isProtectedDataAvailable))",
            "Available storage bytes: \(environment.availableStorageBytes.map(String.init) ?? "Unknown")",
            "",
            "[Settings]",
            "Appearance: \(settings.appearanceMode)",
            "Start page: \(settings.startTab)",
            "Default dashboard configured: \(yesNo(settings.defaultDashboardConfigured))",
            "Currency: \(settings.currencyCode)",
            "Number format: \(settings.numberFormat)",
            "Narrow currency symbol: \(yesNo(settings.useNarrowCurrencySymbol))",
            "",
            "Budget view style: \(settings.budgetDisplayStyle)",
            "Show compact budget overview: \(yesNo(settings.showCompactBudgetOverview))\(settings.budgetDisplayStyle == "clean" ? " (inactive in Clean view)" : "")",
            "Show spent: \(yesNo(settings.showCompactSpentColumn))\(settings.budgetDisplayStyle == "clean" ? " (inactive in Clean view)" : "")",
            "Budgeted amounts: \(yesNo(settings.showBudgetedAmounts))",
            "Group totals: \(yesNo(settings.showGroupTotals))\(settings.budgetDisplayStyle == "clean" ? " (inactive in Clean view)" : "")",
            "Budget status filters: \(yesNo(settings.showBudgetCheckInStrip))",
            "Hide spent categories: \(yesNo(settings.hideZeroBudgetCategories))",
            "Show hidden categories: \(yesNo(settings.showHiddenCategories))",
            "Category status dots: \(yesNo(settings.showCategoryStatusDots))",
            "Custom category status colors: \(settings.customCategoryStatusColorCount)",
            "Budget progress bars: \(yesNo(settings.showBudgetProgressBars))",
            "Inverse progress bars: \(yesNo(settings.showInverseBudgetProgressBars))\(!settings.showBudgetProgressBars ? " (inactive; progress bars disabled)" : "")",
            "Categories with hidden progress bars: \(settings.hiddenBudgetProgressCategoryCount)",
            "Categories excluded from spent: \(settings.spentCategoryExclusionCount)",
            "Overspent badge: \(yesNo(settings.showOverspentBadge))",
            "Hide income group: \(yesNo(settings.hideIncomeGroup))",
            "Budget goal templates: \(yesNo(settings.goalTemplatesEnabled))",
            "Automations editor: \(yesNo(settings.goalTemplatesUIEnabled))\(!settings.goalTemplatesEnabled ? " (inactive; goal templates disabled)" : "")",
            "",
            "Transaction display: \(settings.transactionDisplayMode)",
            "Transaction status filter: \(settings.transactionStatusFilter)",
            "Transaction status filters: \(yesNo(settings.showTransactionStatusFilters))",
            "Uncategorized action: \(settings.uncategorizedTapAction)",
            "Conventional amount entry: \(yesNo(settings.conventionalAmountEntry))",
            "Default account configured: \(yesNo(settings.defaultAccountConfigured))",
            "Record payee locations: \(yesNo(settings.recordPayeeLocations))",
            "Payee location writes supported: \(yesNo(settings.payeeLocationWritesSupported))",
            "",
            "Hide balances: \(yesNo(settings.hideBalances))",
            "Shake to toggle balances: \(yesNo(settings.shakeToHideBalances))",
            "Hide decimal places: \(yesNo(settings.hideDecimalPlaces))",
            "Hide closed accounts: \(yesNo(settings.hideClosedAccounts))",
            "",
            "New transaction alerts: \(yesNo(settings.transactionNotificationsEnabled))",
            "Credit card due reminders: \(yesNo(settings.creditCardDueNotificationsEnabled))",
            "",
            "Card & account mappings: \(settings.cardAccountMappingCount)",
            "Credit card configurations: \(settings.creditCardConfigurationCount)",
            "Loan configurations: \(settings.loanConfigurationCount)",
            "Deposit configurations: \(settings.depositConfigurationCount)",
            "Category funding configured: \(yesNo(settings.categoryFundingConfigured))",
            "Category funding enabled: \(yesNo(settings.categoryFundingEnabled))",
            "Category funding source: \(settings.categoryFundingSource)",
            "",
            "[Connection]",
            "Server configured: \(yesNo(snapshot.serverConfigured))",
            "Server transport: \(snapshot.serverTransport)",
            "Fallback configured: \(yesNo(snapshot.fallbackConfigured))",
            "Current server route: \(snapshot.serverRoute)",
            "Custom headers configured: \(yesNo(snapshot.customHeadersConfigured))",
            "Connection status: \(snapshot.connectionStatus.rawValue)",
            "Credential present: \(yesNo(snapshot.credentialPresent))",
            "Last HTTP status: \(snapshot.lastNetworkStatusCode.map(String.init) ?? "none")",
            "Last network error: \(snapshot.lastNetworkError?.diagnosticDescription ?? "none")",
            "",
            "[Sync Status]",
            "Last sync attempt: \(timestamp(snapshot.lastSyncAttemptAt))",
            "Last sync success: \(timestamp(snapshot.lastSyncSuccessAt))",
            "Last sync result: \(snapshot.lastSyncResult?.rawValue ?? "none")",
            "Last sync duration: \(snapshot.lastSyncDurationMilliseconds.map { "\($0) ms" } ?? "none")",
            "Last sync request messages: \(snapshot.lastSyncRequestMessageCount.map(String.init) ?? "none")",
            "Last sync response messages: \(snapshot.lastSyncResponseMessageCount.map(String.init) ?? "none")",
            "",
            "[Diagnostic Event History]",
            "Scope: app session; events may include earlier budget or connection configurations.",
            "Retained events: \(snapshot.entries.count)"
        ]

        if snapshot.entries.isEmpty {
            lines.append("No diagnostic events recorded.")
        } else {
            for (index, entry) in snapshot.entries.enumerated() {
                lines.append("\(index + 1). \(timestamp(entry.date)) | \(entry.message)")
            }
        }

        lines += [
            "",
            "End of report",
            ""
        ]

        return DiagnosticReport(
            text: lines.joined(separator: "\n"),
            filename: "Actuali-Diagnostics-\(filenameTimestamp(generatedAt)).txt"
        )
    }

    private static func thermalState(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            "nominal"
        case .fair:
            "fair"
        case .serious:
            "serious"
        case .critical:
            "critical"
        @unknown default:
            "unknown"
        }
    }

    private static func applicationState(_ state: UIApplication.State) -> String {
        switch state {
        case .active:
            "active"
        case .inactive:
            "inactive"
        case .background:
            "background"
        @unknown default:
            "unknown"
        }
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private static func timestamp(_ date: Date?) -> String {
        guard let date else {
            return "never"
        }
        return diagnosticTimestampFormatter.string(from: date)
    }

    private static func filenameTimestamp(_ date: Date) -> String {
        diagnosticFilenameFormatter.string(from: date)
    }

    private static let diagnosticTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let diagnosticFilenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss'Z'"
        return formatter
    }()
}
@MainActor
struct DiagnosticReportView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @State private var snapshot: DiagnosticLogSnapshot = .empty
    @State private var settings: DiagnosticSettingsSnapshot = .empty
    @State private var environment = DiagnosticReportEnvironment.empty
    @State private var copied = false
    @State private var generatedAt = Date()

    private var report: DiagnosticReport {
        DiagnosticReportBuilder.make(
            snapshot: snapshot,
            settings: settings,
            environment: environment,
            generatedAt: generatedAt
        )
    }

    var body: some View {
        ScrollView {
            Text(report.text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .readableWidth()
        .navigationTitle(String(localized: "Diagnostic Report"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(
                    item: report,
                    preview: SharePreview(
                        String(localized: "Diagnostic Report"),
                        image: Image(systemName: "doc.text")
                    )
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(String(localized: "Share Diagnostic Report"))
                .accessibilityIdentifier("diagnosticReport.share")

                Button {
                    UIPasteboard.general.string = report.text
                    copied = true
                } label: {
                    Label(
                        copied
                            ? String(localized: "Diagnostic Report Copied")
                            : String(localized: "Copy Diagnostic Report"),
                        systemImage: copied ? "checkmark.circle" : "doc.on.doc"
                    )
                }
                .accessibilityIdentifier("diagnosticReport.copy")
            }
        }
        .task {
            environment = DiagnosticReportEnvironment.capture()
            while !Task.isCancelled {
                generatedAt = Date()
                snapshot = await DiagnosticLog.shared.snapshot()
                settings = DiagnosticSettingsSnapshot.capture(from: budgetStore)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

#Preview {
    NavigationStack {
        DiagnosticReportView()
            .environmentObject(BudgetStore.previewInstance())
    }
}
