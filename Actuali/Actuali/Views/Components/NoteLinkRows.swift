import SwiftUI

/// Tappable rows for the links in a note being edited (GH #190). Edit
/// surfaces keep the raw text editable — a TextField can't render tappable
/// links — so any markdown links or bare URLs in the draft surface as rows
/// beneath the field, updating live as the user types.
struct NoteLinkRows: View {
    let text: String

    var body: some View {
        ForEach(NoteLinkText.links(in: text)) { link in
            Link(destination: link.url) {
                Label(link.label, systemImage: "link")
                    .lineLimit(1)
            }
            .accessibilityIdentifier("noteLinkRow")
        }
    }
}

#Preview {
    Form {
        Section {
            Text("Groceries note")
            NoteLinkRows(text: "See [Amazon order](https://amazon.com/gp/order/123) or https://example.com/r/9")
        }
    }
}
