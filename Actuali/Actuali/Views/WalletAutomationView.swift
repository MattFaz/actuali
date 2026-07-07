import SwiftUI

private let webGuideURL = URL(string: "https://actuali.mfazz.com/guides/wallet-automation")!
private let shortcutsAppURL = URL(string: "shortcuts://")!

/// Walks the user through creating a Shortcuts "Transaction" automation so
/// tap-to-pay purchases from Apple Wallet log into Actuali automatically.
/// There is nothing to install — the Log Transaction action ships with the
/// app as an App Intent; each Wallet card needs its own automation.
struct WalletAutomationView: View {
    private static let steps = [
        "Open the Shortcuts app and go to the Automation tab.",
        "Tap New Automation, then search for and choose Wallet.",
        "Select the Wallet card you want to track, keep Run Immediately, and tap Next.",
        "Choose Create New Shortcut.",
        "Tap Add Action and search for Log Transaction from Actuali.",
        "Tap the action's Amount field, tap Select Variable, then choose Shortcut Input.",
        "Repeat for Payee: tap the Shortcut Input variable and change it to Merchant (or Name).",
        "Tap Account and select the account that matches this card."
    ]

    var body: some View {
        List {
            Section {
                Text("Log tap-to-pay purchases automatically. When you pay with a card in Apple Wallet, a Shortcuts automation runs Actuali's Log Transaction action in the background — no need to open the app.")
            }

            Section {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.subheadline.monospacedDigit().bold())
                            .foregroundStyle(.secondary)
                        Text(step)
                    }
                }
            } header: {
                Text("Set It Up")
            } footer: {
                Text("Repeat for each card you want to track. If you skip the Account step, transactions go to your Default Account. Actuali confirms each logged purchase with a notification.")
            }

            Section {
                Link(destination: shortcutsAppURL) {
                    Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                }
                Link(destination: webGuideURL) {
                    Label("View Guide with Screenshots", systemImage: "safari")
                }
            }
        }
        .navigationTitle("Wallet Automation")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        WalletAutomationView()
    }
}
