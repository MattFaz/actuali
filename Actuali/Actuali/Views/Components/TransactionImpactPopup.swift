import SwiftUI

/// Floating glass cards that show how the last transaction change moved each
/// budget category's available balance: before, the change, after. Driven by
/// `BudgetStore.transactionImpactCues`; tapping dismisses it early.
struct TransactionImpactPopup: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    var body: some View {
        ViewThatFits(in: .vertical) {
            cards
            ScrollView {
                cards
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxHeight: 300, alignment: .bottom)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var cards: some View {
        VStack(spacing: 8) {
            ForEach(budgetStore.transactionImpactCues) { cue in
                TransactionImpactCard(cue: cue)
            }
        }
    }
}

private struct TransactionImpactCard: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale

    let cue: TransactionImpactCue

    private var accent: Color {
        cue.isExpense ? .red : .green
    }

    /// The month is named only when it isn't the current one, so a change to
    /// an older transaction doesn't look like it hit this month's balance.
    private var monthTitle: String? {
        cue.month == TransactionImpact.month(forDate: Transaction.yyyymmdd(from: Date())) ? nil : MonthPicker.title(for: cue.month, locale: locale)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: cue.isExpense ? "arrow.down.right" : "arrow.up.right")
                .font(.headline.weight(.bold))
                .foregroundStyle(accent)
                .frame(width: 40, height: 40)
                .background(accent.opacity(0.18), in: Circle())

            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text(cue.categoryName)
                        .font(.headline)
                        .lineLimit(1)
                    if let monthTitle {
                        Text(monthTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack {
                    Text(budgetStore.displayBalance(cue.balanceBeforeCents))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text((cue.deltaCents > 0 ? "+" : "") + budgetStore.displayBalance(cue.deltaCents))
                        .fontWeight(.semibold)
                        .foregroundStyle(accent)
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(budgetStore.displayBalance(cue.balanceAfterCents))
                        .fontWeight(.bold)
                        .foregroundStyle(cue.balanceAfterCents < 0 ? Color.red : Color.primary)
                }
                .font(.body.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .modifier(TransactionImpactGlass())
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture {
            budgetStore.dismissTransactionImpactCues()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(budgetStore.spokenImpactText(cue))
        .accessibilityHint(Text("Double-tap to dismiss"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("transactionImpactCue.\(cue.id)")
    }
}

/// Liquid Glass on iOS 26 and a material before that. Both sit on a mostly
/// opaque backing, with a hairline edge and a deeper shadow, so the card
/// stays readable over busy list rows instead of dissolving into them.
private struct TransactionImpactGlass: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                content
                    .background(Color(.systemBackground).opacity(0.8), in: shape)
                    .glassEffect(.regular, in: shape)
            } else {
                content
                    .background(.regularMaterial, in: shape)
                    .background(Color(.systemBackground).opacity(0.6), in: shape)
            }
        }
        .overlay(shape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }
}
