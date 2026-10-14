import Foundation
import LocalAuthentication
import Testing
@testable import Actuali

/// GH #717: App Lock covers the app after backgrounding and on launch, and
/// only an authenticated user gets back in or turns the lock on.
///
/// Serialized and restoring `requireAppUnlock`: the test host shares its
/// defaults with the installed app, and a leftover `true` would launch it
/// locked behind a prompt no automated run can answer.
@MainActor
@Suite(.serialized)
struct BudgetStoreAppLockTests {
    private static let key = "requireAppUnlock"

    /// Answers every prompt with `result` and counts them.
    private final class Prompter {
        var result: Bool
        var count = 0
        init(result: Bool) {
            self.result = result
        }
    }

    private func makeStore(
        authenticates: Bool,
        _ store: BudgetStore = .previewInstance()
    ) -> (BudgetStore, Prompter) {
        let prompter = Prompter(result: authenticates)
        store.setAuthenticatorForTesting { _ in
            prompter.count += 1
            return prompter.result
        }
        return (store, prompter)
    }

    @Test func backgroundingDoesNothingWhileOff() async {
        let (store, prompter) = makeStore(authenticates: true)
        store.lockApp()
        await store.promptAppUnlockIfPending()
        #expect(!store.isAppLocked)
        #expect(prompter.count == 0)
    }

    @Test func enablingRequiresAuthentication() async {
        let saved = UserDefaults.standard.object(forKey: Self.key)
        defer { restoreUserDefault(Self.key, to: saved) }
        let (store, prompter) = makeStore(authenticates: false)
        await store.enableAppLock()
        #expect(!store.requireAppUnlock)
        prompter.result = true
        await store.enableAppLock()
        #expect(store.requireAppUnlock)
        #expect(UserDefaults.standard.object(forKey: Self.key) as? Bool == true)
        store.requireAppUnlock = false
        #expect(UserDefaults.standard.object(forKey: Self.key) as? Bool == false)
    }

    @Test func coldLaunchStartsLockedAndPrompts() async {
        let saved = UserDefaults.standard.object(forKey: Self.key)
        defer { restoreUserDefault(Self.key, to: saved) }
        UserDefaults.standard.set(true, forKey: Self.key)
        let (store, prompter) = makeStore(
            authenticates: true,
            .previewInstanceLoadingPersistedPreferencesForTesting()
        )
        #expect(store.isAppLocked)
        await store.promptAppUnlockIfPending()
        #expect(!store.isAppLocked)
        #expect(prompter.count == 1)
    }

    @Test func returningPromptsOnceAndUnlocks() async {
        let saved = UserDefaults.standard.object(forKey: Self.key)
        defer { restoreUserDefault(Self.key, to: saved) }
        let (store, prompter) = makeStore(authenticates: true)
        store.requireAppUnlock = true
        store.lockApp()
        #expect(store.isAppLocked)
        await store.promptAppUnlockIfPending()
        #expect(!store.isAppLocked)
        #expect(prompter.count == 1)
    }

    /// A cancelled prompt bounces the scene inactive → active; that must not
    /// re-prompt in a loop, but the Unlock button must still work.
    @Test func cancelledPromptStaysLockedWithoutRePrompting() async {
        let saved = UserDefaults.standard.object(forKey: Self.key)
        defer { restoreUserDefault(Self.key, to: saved) }
        let (store, prompter) = makeStore(authenticates: false)
        store.requireAppUnlock = true
        store.lockApp()
        await store.promptAppUnlockIfPending()
        await store.promptAppUnlockIfPending()
        #expect(store.isAppLocked)
        #expect(prompter.count == 1)

        prompter.result = true
        await store.unlockApp()
        #expect(!store.isAppLocked)
    }

    @Test func turningOffUnlocks() {
        let saved = UserDefaults.standard.object(forKey: Self.key)
        defer { restoreUserDefault(Self.key, to: saved) }
        let (store, _) = makeStore(authenticates: false)
        store.requireAppUnlock = true
        store.lockApp()
        store.requireAppUnlock = false
        #expect(!store.isAppLocked)
    }

    @Test func toggleTitleNamesTheDevicesBiometry() {
        #expect(PrivacySettingsView.appLockTitle(for: .faceID) == String(localized: "Require Face ID"))
        #expect(PrivacySettingsView.appLockTitle(for: .touchID) == String(localized: "Require Touch ID"))
        #expect(PrivacySettingsView.appLockTitle(for: .none) == String(localized: "Require Passcode"))
    }
}
