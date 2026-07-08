//
//  ActualiApp.swift
//  Actuali
//
//  Created by Matt Farrell on 9/12/2025.
//

import SwiftUI

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
