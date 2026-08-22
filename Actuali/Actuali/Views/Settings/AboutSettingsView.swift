import SwiftUI

private let actualBudgetWebsiteURL = URL(string: "https://actualbudget.org")!
private let privacyPolicyURL = URL(string: "https://actuali.mfazz.com/privacy")!
private let contactEmailURL = URL(string: "mailto:actuali@mfazz.com")!
private let supportURL = URL(string: "https://actuali.mfazz.com/support")!
private let issueTrackerURL = URL(string: "https://github.com/MattFaz/actuali/issues")!

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
            Section("App Information") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Help & Links") {
                Link("Privacy Policy", destination: privacyPolicyURL)
                Link("Contact", destination: contactEmailURL)
                Link("Report an Issue", destination: issueTrackerURL)
                Link("Support", destination: supportURL)
                Link("Actual Budget Website", destination: actualBudgetWebsiteURL)
            }
        }
        .readableWidth()
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.horizontal, 6, for: .scrollContent)
    }
}
