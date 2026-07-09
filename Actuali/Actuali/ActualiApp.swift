//
//  ActualiApp.swift
//  Actuali
//
//  Created by Matt Farrell on 9/12/2025.
//

import SwiftUI
import UserNotifications

@main
struct ActualiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var budgetStore = BudgetStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(budgetStore)
                .preferredColorScheme(budgetStore.appearanceMode.colorScheme)
                .task {
                    #if DEBUG
                    if CommandLine.arguments.contains("-loadDemoData") {
                        await budgetStore.loadDemoData()
                    }
                    // Posts the same failure notification LogTransactionIntent
                    // posts, so the notification-tap flow can be exercised
                    // end-to-end by ActualiUITests.
                    if CommandLine.arguments.contains("-postFailureNotification") {
                        try? await Task.sleep(for: .seconds(2))
                        // Clear leftovers from a previous UI-test run so the
                        // test taps our banner, not a stale one.
                        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                        await TransactionLogNotifier.notifyFailure(
                            message: "Repro: couldn't log transaction.",
                            payee: "Debug Payee",
                            amountCents: 1234,
                            prefill: TransactionPrefill(
                                accountId: nil,
                                payee: "Debug Payee",
                                amountCents: 1234,
                                date: Date()
                            )
                        )
                    }
                    // Same idea for the success path: posts the real success
                    // notification so ActualiUITests can tap it and assert
                    // the All Accounts navigation.
                    if CommandLine.arguments.contains("-postSuccessNotification") {
                        try? await Task.sleep(for: .seconds(2))
                        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                        await TransactionLogNotifier.notifySuccess(
                            payee: "Debug Payee",
                            amountCents: 1234,
                            currencyCode: "USD"
                        )
                    }
                    #endif
                }
                .onChange(of: scenePhase) { oldPhase, newPhase in
                    if newPhase == .active && oldPhase != .active {
                        Task {
                            await budgetStore.syncOnForeground()
                        }
                    }
                }
        }
    }
}
