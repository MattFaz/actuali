import SwiftUI

private let actualBudgetWebsiteURL = URL(string: "https://actualbudget.org")!
private let privacyPolicyURL = URL(string: "https://actuali.mfazz.com/privacy")!

struct AboutSettingsView: View {
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "Unknown"
        return "\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section(String(localized: "App Information")) {
                HStack {
                    Text(String(localized: "Version"))
                    Spacer()
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }
            }

            Section(String(localized: "Help & Links")) {
                Link(String(localized: "Privacy Policy"), destination: privacyPolicyURL)
                NavigationLink {
                    SupportView()
                } label: {
                    Text(String(localized: "Support"))
                }
                Link(String(localized: "Actual Budget Website"), destination: actualBudgetWebsiteURL)
            }
        }
        .readableWidth()
        .navigationTitle(String(localized: "About"))
        .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.horizontal, 6, for: .scrollContent)
    }
}
