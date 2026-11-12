//
//  ContentView.swift
//  Actuali
//
//  Created by Matt Farrell on 9/12/2025.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @StateObject private var notificationRouter = NotificationRouter.shared
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// What the window measures, read once per layout pass: width and horizontal
    /// insets together, so a fold resizes the layout in one go.
    private struct WindowMetrics: Equatable {
        var width: CGFloat = 0
        var insets = WindowInsets()
    }

    /// Window width, measured here rather than deeper in the hierarchy so it
    /// doesn't move when a sidebar expands. Feeds `\.isWideLayout`.
    @State private var metrics = WindowMetrics()

    nonisolated static func tab(forDeepLink url: URL) -> Int? {
        let host = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch host {
        case "add-transaction":
            return StartTab.addTransaction.tabTag
        case "budget":
            return StartTab.budget.tabTag
        case "accounts":
            return StartTab.accounts.tabTag
        default:
            return nil
        }
    }

    /// Presents whenever the store publishes an error; dismissing clears it
    /// so the next failure can present again.
    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { budgetStore.error != nil },
            set: {
                if !$0 {
                    budgetStore.error = nil
                }
            }
        )
    }

    var body: some View {
        MainTabView()
            .onGeometryChange(for: WindowMetrics.self) { proxy in
                WindowMetrics(
                    width: proxy.size.width,
                    insets: WindowInsets(
                        leading: proxy.safeAreaInsets.leading,
                        trailing: proxy.safeAreaInsets.trailing
                    )
                )
            } action: { metrics = $0 }
            .environment(\.windowHorizontalInsets, metrics.insets)
            .environment(\.isWideLayout, WideLayout.isWide(
                sizeClass: sizeClass,
                width: metrics.width
            ))
            .background(ShakeResponder(
                isEnabled: budgetStore.shakeToHideBalances,
                onShake: budgetStore.handleDeviceShake
            ))
            .onOpenURL { url in
                if let tab = Self.tab(forDeepLink: url) {
                    notificationRouter.pendingTabNavigation = tab
                }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: budgetStore.shakeFeedbackTrigger)
            .alert("Something Went Wrong", isPresented: errorAlertBinding) {
                Button("OK") {}
            } message: {
                Text(budgetStore.error ?? "")
            }
            .sheet(item: $notificationRouter.pendingPrefill) { prefill in
                if let accountId = resolvedAccountId(for: prefill) {
                    AddTransactionView(
                        accountId: accountId,
                        payee: prefill.payee,
                        amountCents: prefill.amountCents,
                        date: prefill.date,
                        notes: prefill.notes,
                        categoryId: prefill.categoryId,
                        isIncome: prefill.isIncome,
                        cleared: prefill.cleared
                    )
                } else {
                    ContentUnavailableView(
                        "No Accounts",
                        systemImage: "building.columns",
                        description: Text("Add an account to create transactions")
                    )
                }
            }
            .sheet(item: $notificationRouter.destination) { destination in
                switch destination {
                case .editor(let transaction):
                    AddTransactionView(editing: transaction)
                        .environmentObject(budgetStore)
                case .uncategorized:
                    NavigationStack {
                        UncategorizedTransactionsView()
                    }
                    .environmentObject(budgetStore)
                }
            }
    }

    /// The notification's account if it is still open, else the default
    /// account, else any open account (mirrors `AddTransactionTabView`).
    private func resolvedAccountId(for prefill: TransactionPrefill) -> String? {
        let openAccounts = budgetStore.accounts.filter { !$0.closed }
        if let id = prefill.accountId, openAccounts.contains(where: { $0.id == id }) {
            return id
        }
        if let id = budgetStore.defaultAccountId, openAccounts.contains(where: { $0.id == id }) {
            return id
        }
        return openAccounts.first?.id
    }
}

private struct ShakeResponder: UIViewRepresentable {
    let isEnabled: Bool
    let onShake: @MainActor () -> Void

    func makeUIView(context: Context) -> ShakeResponderView {
        ShakeResponderView(isEnabled: isEnabled, onShake: onShake)
    }

    func updateUIView(_ view: ShakeResponderView, context: Context) {
        view.update(isEnabled: isEnabled, onShake: onShake)
    }
}

@MainActor
final class ShakeResponderView: UIView {
    private var isEnabled: Bool
    private var onShake: @MainActor () -> Void

    init(isEnabled: Bool, onShake: @escaping @MainActor () -> Void) {
        self.isEnabled = isEnabled
        self.onShake = onShake
        super.init(frame: .zero)

        for name in [
            UIResponder.keyboardDidHideNotification,
            UITextField.textDidEndEditingNotification,
            UITextView.textDidEndEditingNotification,
            UIWindow.didBecomeKeyNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(reclaimFirstResponder),
                name: name,
                object: nil
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var canBecomeFirstResponder: Bool {
        isEnabled
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateFirstResponder()
    }

    func update(isEnabled: Bool, onShake: @escaping @MainActor () -> Void) {
        self.onShake = onShake
        guard self.isEnabled != isEnabled else { return }
        self.isEnabled = isEnabled
        updateFirstResponder()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard isEnabled, motion == .motionShake else {
            super.motionEnded(motion, with: event)
            return
        }
        onShake()
    }

    @objc private func reclaimFirstResponder() {
        updateFirstResponder()
    }

    private func updateFirstResponder() {
        if isEnabled, window != nil {
            becomeFirstResponder()
        } else if isFirstResponder {
            resignFirstResponder()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(BudgetStore.previewInstance())
}
