import SwiftUI

private let webGuideURL = URL(string: "https://actuali.mfazz.com/guides/wallet-automation")!
private let shortcutsAppURL = URL(string: "shortcuts://")!

/// Walks the user through creating a Shortcuts "Transaction" automation so
/// tap-to-pay purchases from Apple Wallet log into Actuali automatically.
/// There is nothing to install — the Log Transaction action ships with the
/// app as an App Intent; each Wallet card needs its own automation.
struct WalletAutomationView: View {
    private static let steps = [
        String(localized: "wallet.automation.step1"),
        String(localized: "wallet.automation.step2"),
        String(localized: "wallet.automation.step3"),
        String(localized: "wallet.automation.step4"),
        String(localized: "wallet.automation.step5"),
        String(localized: "wallet.automation.step6"),
        String(localized: "wallet.automation.step7"),
        String(localized: "wallet.automation.step8")
    ]

    var body: some View {
        List {
            Section {
                Text(String(localized: "wallet.automation.intro"))
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
                Text(String(localized: "Set It Up"))
            } footer: {
                Text(String(localized: "wallet.automation.footer"))
            }

            Section {
                Link(destination: shortcutsAppURL) {
                    Label(String(localized: "Open Shortcuts"), systemImage: "arrow.up.forward.app")
                }
                Link(destination: webGuideURL) {
                    Label(String(localized: "View Guide with Screenshots"), systemImage: "safari")
                }
            }
        }
        .navigationTitle(String(localized: "Wallet Automation"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        WalletAutomationView()
    }
}
