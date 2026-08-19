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
            let status = BackgroundRefreshStatus()
            status.lastRun = nil
            status.lastScheduleAttempt = nil
            status.lastScheduleError = nil
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
                    // Stands in for coordinates the Add Transaction form would
                    // have recorded, so PayeeLocationsUITests can clear them.
                    if CommandLine.arguments.contains("-seedPayeeLocations") {
                        await budgetStore.seedDebugPayeeLocations(payeeName: "Whole Foods")
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
                            currencyCode: budgetStore.currencyCode,
                            narrowSymbol: budgetStore.useNarrowCurrencySymbol,
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
                        // Submitting here as well as on backgrounding covers a
                        // first launch that never backgrounds cleanly and
                        // retries a submit that failed last time; a duplicate
                        // submit just replaces the pending request.
                        BackgroundRefresh.schedule()
                        Task {
                            await budgetStore.syncOnForeground()
                        }
                    }
                    if newPhase == .background {
                        BackgroundRefresh.schedule()
                        budgetStore.backupOnBackground()
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
                .animation(AppAnimation.appearance, value: budgetStore.schedulePostNotice)
        }
    }
}
