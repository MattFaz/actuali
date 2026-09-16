import SwiftUI

private let discordURL = URL(string: "https://discord.gg/PDcJDPYpDG")!
private let githubURL = URL(string: "https://github.com/MattFaz/actuali")!
private let contactEmailURL = URL(string: "mailto:actuali@mfazz.com")!
private let supportSiteURL = URL(string: "https://actuali.mfazz.com/support")!

struct SupportView: View {
    var body: some View {
        Form {
            Section(String(localized: "Help & Links")) {
                Link(destination: supportSiteURL) {
                    Label(String(localized: "Help & FAQ"), systemImage: "questionmark.circle")
                }
                .accessibilityIdentifier("support.website")
                Link(destination: discordURL) {
                    Label(String(localized: "Discord"), systemImage: "bubble.left.and.bubble.right")
                }
                .accessibilityIdentifier("support.discord")
                Link(destination: githubURL) {
                    Label(String(localized: "GitHub"), systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .accessibilityIdentifier("support.github")
                Link(destination: contactEmailURL) {
                    Label(String(localized: "Email"), systemImage: "envelope")
                }
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
