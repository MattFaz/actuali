import SwiftUI

/// A shared capsule search field for screens that need explicit, on-demand search
/// on iOS versions before the native minimized toolbar search is available.
struct GlassSearchBar: View {
    @Binding private var text: String
    @FocusState.Binding private var isFocused: Bool
    private let prompt: LocalizedStringKey
    private let accessibilityPrefix: String

    init(
        text: Binding<String>,
        isFocused: FocusState<Bool>.Binding,
        prompt: LocalizedStringKey,
        accessibilityPrefix: String
    ) {
        _text = text
        _isFocused = isFocused
        self.prompt = prompt
        self.accessibilityPrefix = accessibilityPrefix
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isFocused)
                .accessibilityIdentifier("\(accessibilityPrefix).searchField")
                .onSubmit { isFocused = false }
                // The field is inserted only when search is presented.
                .task { isFocused = true }
            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear Search"))
                .accessibilityIdentifier("\(accessibilityPrefix).searchClear")
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 12)
    }

    var body: some View {
        field
            .background(.quaternary, in: Capsule())
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }
}

/// Uses the system's minimized Liquid Glass search control on iOS 26+, with the
/// shared custom field as a fallback on older supported OS versions.
private struct OnDemandSearchModifier: ViewModifier {
    @Binding private var text: String
    @Binding private var isPresented: Bool
    @FocusState.Binding private var isFocused: Bool
    private let prompt: LocalizedStringKey
    private let accessibilityPrefix: String

    init(
        text: Binding<String>,
        isPresented: Binding<Bool>,
        isFocused: FocusState<Bool>.Binding,
        prompt: LocalizedStringKey,
        accessibilityPrefix: String
    ) {
        _text = text
        _isPresented = isPresented
        _isFocused = isFocused
        self.prompt = prompt
        self.accessibilityPrefix = accessibilityPrefix
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .searchable(
                    text: $text,
                    isPresented: $isPresented,
                    placement: .toolbar,
                    prompt: Text(prompt)
                )
                .searchFocused($isFocused)
                .searchToolbarBehavior(.minimize)
                .onChange(of: isPresented) { _, presented in
                    guard !presented else { return }
                    isFocused = false
                    text = ""
                }
        } else {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    if isPresented {
                        GlassSearchBar(
                            text: $text,
                            isFocused: $isFocused,
                            prompt: prompt,
                            accessibilityPrefix: accessibilityPrefix
                        )
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isPresented.toggle()
                            if !isPresented {
                                isFocused = false
                                text = ""
                            }
                        } label: {
                            Image(systemName: isPresented ? "xmark" : "magnifyingglass")
                        }
                        .accessibilityLabel(isPresented ? Text("Cancel Search") : Text(prompt))
                        .accessibilityIdentifier("\(accessibilityPrefix).search")
                    }
                }
        }
    }
}

extension View {
    func onDemandSearch(
        text: Binding<String>,
        isPresented: Binding<Bool>,
        isFocused: FocusState<Bool>.Binding,
        prompt: LocalizedStringKey,
        accessibilityPrefix: String
    ) -> some View {
        modifier(
            OnDemandSearchModifier(
                text: text,
                isPresented: isPresented,
                isFocused: isFocused,
                prompt: prompt,
                accessibilityPrefix: accessibilityPrefix
            )
        )
    }
}
