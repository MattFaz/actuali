import SwiftUI

/// Editor for user-defined HTTP headers sent on every server request. Edits a
/// local draft and commits back to the bound array on disappear, so the store
/// (and its Keychain write) is only touched once per visit rather than per
/// keystroke.
struct CustomHeadersEditor: View {
    @Binding var headers: [CustomHeader]
    @State private var draft: [CustomHeader] = []

    var body: some View {
        Form {
            Section {
                ForEach($draft) { $header in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Header name", text: $header.name)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.subheadline.weight(.medium))
                        TextField("Value", text: $header.value)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { draft.remove(atOffsets: $0) }

                Button {
                    draft.append(CustomHeader())
                } label: {
                    Label("Add header", systemImage: "plus")
                }
            } footer: {
                Text("Sent with every request to your server. For Cloudflare Access, add a service token as two headers: CF-Access-Client-Id and CF-Access-Client-Secret.")
            }
        }
        .readableWidth()
        .navigationTitle("Custom HTTP Headers")
        .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.horizontal, 6, for: .scrollContent)
        .toolbar { EditButton() }
        .onAppear {
            if draft.isEmpty { draft = headers }
        }
        .onDisappear {
            let cleaned = draft.filter {
                !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
            }
            if cleaned != headers {
                headers = cleaned
            }
        }
    }
}
