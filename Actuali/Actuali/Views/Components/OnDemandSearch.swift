import SwiftUI

/// The capsule search field used on iOS versions before the native minimized
/// toolbar search is available.
struct CapsuleSearchField: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let prompt: LocalizedStringKey
    let accessibilityPrefix: String

    var body: some View {
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
        .background(.quaternary, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Uses the system's minimized Liquid Glass search control on iOS 26+, with
/// `CapsuleSearchField` as a fallback on older supported OS versions.
struct OnDemandSearchModifier: ViewModifier {
    @Binding var text: String
    @Binding var isPresented: Bool
    @FocusState.Binding var isFocused: Bool
    let prompt: LocalizedStringKey
    let accessibilityPrefix: String

    /// iOS 27.0–27.2 break a minimized toolbar search inside a `TabView`: once
    /// opened it cannot be dismissed (developer.apple.com/forums/thread/845737).
    /// Fixed in 27.3, so those releases get the fallback.
    nonisolated static func usesNativeSearch(_ os: OperatingSystemVersion) -> Bool {
        let version = (os.majorVersion, os.minorVersion)
        return version >= (26, 0) && (version < (27, 0) || version >= (27, 3))
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), Self.usesNativeSearch(ProcessInfo.processInfo.operatingSystemVersion) {
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
                        CapsuleSearchField(
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
