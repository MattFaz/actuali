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

    init() {
        // BGTaskScheduler requires all handlers registered before launch ends.
        // (The notification delegate is set in AppDelegate.)
        BackgroundRefresh.register()
        #if DEBUG
        // Clean slate so BackgroundRefreshRowUITests always starts at "Never"
        // regardless of what earlier runs left in UserDefaults.
        if CommandLine.arguments.contains("-stampBackgroundRefreshOnBackground") {
            BackgroundRefreshStatus().lastRun = nil
        }
        #endif
    }

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
                    if newPhase == .background {
                        BackgroundRefresh.schedule()
                        #if DEBUG
                        // Stands in for a real background-refresh fire, which
                        // can't be triggered from a UI test: writes the same
                        // timestamp handle() writes, while Settings is not
                        // active — exactly the state the Settings row must
                        // recover from on reactivation.
                        if CommandLine.arguments.contains("-stampBackgroundRefreshOnBackground") {
                            BackgroundRefreshStatus().lastRun = Date()
                        }
                        #endif
                    }
                }
                .overlay(alignment: .top) {
                    if let notice = budgetStore.schedulePostNotice {
                        ToastView(text: notice)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: budgetStore.schedulePostNotice)
        }
    }
}
