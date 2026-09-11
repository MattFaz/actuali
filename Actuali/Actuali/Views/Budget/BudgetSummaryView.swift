import SwiftUI

/// Actions available from the envelope budget summary result menu.
enum EnvelopeBudgetSummaryAction: Equatable {
    case resetBuffer
    case moveToCategory
    case holdForNextMonth
    case coverFromCategory
}

extension EnvelopeBudgetSummaryAction {
    nonisolated static func available(for summary: EnvelopeBudgetSummary) -> [Self] {
        var actions: [Self] = []

        if summary.manualBuffered > 0 {
            actions.append(.resetBuffer)
        }

        if summary.toBudget > 0 {
            actions.append(.moveToCategory)
            if summary.manualBuffered == 0 && summary.autoBuffered == 0 {
                actions.append(.holdForNextMonth)
            }
        } else if summary.toBudget < 0 {
            actions.append(.coverFromCategory)
        }

        return actions
    }
}

/// Interactive To Budget / Overbudgeted cell used by compact budget summaries.
struct BudgetBufferCompactSummaryStat: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @State private var showingSummary = false

    let stat: CompactBudgetOverview.Stat
    var alignment: HorizontalAlignment = .trailing

    private var displayedLabel: String {
        stat.amount < 0
            ? String(localized: "Overbudgeted", locale: locale)
            : String(localized: "To Budget", locale: locale)
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(displayedLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.65)
                .allowsTightening(!dynamicTypeSize.isAccessibilitySize)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)

            Button {
                showingSummary = true
            } label: {
                Text(budgetStore.displayBudgetCell(stat.amount))
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.35)
                    .allowsTightening(!dynamicTypeSize.isAccessibilitySize)
                    .foregroundStyle(resultColor)
                    .animatedAmount(budgetStore.displayBudgetCell(stat.amount))
            }
            .buttonStyle(.plain)
        }
        .fullScreenCover(isPresented: $showingSummary) {
            if let budget = budgetStore.currentBudgetMonth, budget.toBudget != nil {
                BudgetSummarySheet(month: budget.month)
            }
        }
    }

    private var resultColor: Color {
        switch CompactBalanceTone(amount: stat.amount, isMasked: budgetStore.hideBalances) {
        case .negative: return .red
        case .zero: return .secondary
        case .positive: return .green
        case .masked: return .primary
        }
    }
}

/// Budget summary presented as a centered Liquid Glass card for an envelope budget.
struct BudgetSummarySheet: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var summary: EnvelopeBudgetSummary?
    @State private var showingActions = false
    @State private var showingCategorySheet = false
    @State private var showingHoldSheet = false
    @State private var resetErrorMessage: String?

    let month: String

    private var resultTitle: String {
        (summary?.toBudget ?? 0) < 0
            ? String(localized: "Overbudgeted", locale: locale)
            : String(localized: "To Budget", locale: locale)
    }

    private var previousMonthTitle: String {
        guard let previousMonth = BudgetStore.shiftBudgetMonth(month, by: -1),
              let monthNumber = Int(previousMonth.split(separator: "-").last ?? "0"),
              (1...12).contains(monthNumber) else {
            return String(localized: "Overspent", locale: locale)
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        let monthName = formatter.shortMonthSymbols[monthNumber - 1]
        return String(format: String(localized: "Overspent in %@", locale: locale), monthName)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            glassCard
                .padding(.horizontal, 24)
                .frame(maxWidth: 390)
        }
        .presentationBackground(.clear)
        .task(id: month) { await loadSummary() }
        .alert(
            String(localized: "Unable to reset buffer"),
            isPresented: Binding(
                get: { resetErrorMessage != nil },
                set: { if !$0 { resetErrorMessage = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) { resetErrorMessage = nil }
        } message: {
            Text(resetErrorMessage ?? String(localized: "The buffer could not be reset."))
        }
        .confirmationDialog(
            resultTitle,
            isPresented: $showingActions,
            titleVisibility: .visible
        ) {
            if let summary {
                ForEach(Array(EnvelopeBudgetSummaryAction.available(for: summary).enumerated()), id: \.offset) { _, action in
                    switch action {
                    case .resetBuffer:
                        Button(String(localized: "Reset next month's buffer")) {
                            resetBuffer()
                        }
                    case .moveToCategory:
                        Button(String(localized: "Move to a category")) {
                            showingCategorySheet = true
                        }
                    case .holdForNextMonth:
                        Button(String(localized: "Hold for next month")) {
                            showingHoldSheet = true
                        }
                    case .coverFromCategory:
                        Button(String(localized: "Cover from a category")) {
                            showingCategorySheet = true
                        }
                    }
                }

                Button(String(localized: "Cancel"), role: .cancel) { }
            }
        }
        .sheet(
            isPresented: $showingHoldSheet,
            onDismiss: { Task { await loadSummary() } }
        ) {
            if let summary, summary.toBudget > 0 {
                BudgetBufferSheet(month: month, available: summary.toBudget)
            }
        }
        .sheet(
            isPresented: $showingCategorySheet,
            onDismiss: { Task { await loadSummary() } }
        ) {
            if let current = budgetStore.currentBudgetMonth, let toBudget = current.toBudget {
                BudgetToCategorySheet(
                    budget: current,
                    amount: toBudget,
                    isCovering: toBudget < 0
                )
            }
        }
    }

    @ViewBuilder
    private var glassCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "Budget Summary"))
                    .font(.title3.weight(.semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(localized: "Close Budget Summary")))
            }

            Divider()
                .padding(.vertical, 14)

            if let summary {
                VStack(spacing: 0) {
                    summaryRow(String(localized: "Available Funds"), summary.availableFunds)
                    summaryRow(
                        previousMonthTitle,
                        summary.lastMonthOverspent,
                        tint: summary.lastMonthOverspent < 0 ? .red : .primary
                    )
                    summaryRow(
                        String(localized: "Budgeted"),
                        -summary.budgeted,
                        tint: summary.budgeted > 0 ? .primary : .secondary
                    )
                    summaryRow(
                        String(localized: "For next month"),
                        -summary.forNextMonth,
                        tint: summary.forNextMonth > 0 ? .primary : .secondary
                    )

                    Divider()
                        .padding(.vertical, 14)

                    Button { showingActions = true } label: {
                        HStack(spacing: 12) {
                            Text(resultTitle)
                                .font(.body.weight(.semibold))
                            Spacer()
                            Text(budgetStore.displayBalance(summary.toBudget))
                                .font(.title3.weight(.semibold))
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(summary.toBudget < 0 ? .red : .green)
                    .accessibilityIdentifier("budgetSummaryResultAction")
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .padding(22)
        .background {
            if #available(iOS 26.0, *) {
                Color.clear
            } else {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .modifier(BudgetSummaryGlassModifier())
    }

    @ViewBuilder
    private func summaryRow(
        _ title: String,
        _ amount: Int,
        tint: Color = .primary
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer()
            Text(budgetStore.displayBalance(amount))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
    }

    private func loadSummary() async {
        summary = await budgetStore.fetchEnvelopeBudgetSummary(month)
    }

    private func resetBuffer() {
        Task {
            do {
                try await budgetStore.resetBudgetBuffer(month: month)
                await loadSummary()
            } catch {
                resetErrorMessage = error.localizedDescription
            }
        }
    }
}

private struct BudgetSummaryGlassModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 28))
        } else {
            content.background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
        }
    }
}
