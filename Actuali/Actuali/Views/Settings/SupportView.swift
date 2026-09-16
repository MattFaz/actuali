import SwiftUI

private let discordURL = URL(string: "https://discord.gg/PDcJDPYpDG")!
private let githubURL = URL(string: "https://github.com/MattFaz/actuali")!
private let contactEmailURL = URL(string: "mailto:actuali@mfazz.com")!

struct SupportView: View {
    var body: some View {
        Form {
            Section(String(localized: "Help & Links")) {
                Link(String(localized: "Discord"), destination: discordURL)
                    .accessibilityIdentifier("support.discord")
                Link(String(localized: "GitHub"), destination: githubURL)
                    .accessibilityIdentifier("support.github")
                Link(String(localized: "Email"), destination: contactEmailURL)
                    .accessibilityIdentifier("support.email")
            }
        }
        .readableWidth()
        .navigationTitle(String(localized: "Support"))
        .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.horizontal, 6, for: .scrollContent)
    }
}

#Preview {
    NavigationStack {
        SupportView()
    }
}
