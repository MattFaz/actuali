import Foundation
import Testing
import UIKit
@testable import Actuali

@MainActor
struct AccountIconCustomizationStoreTests {
    @Test func sameAccountCustomizationIsIsolatedByBudget() {
        let (store, defaults, root, suite) = makeStore()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        store.setIconsEnabled(false, for: "budget-a")
        store.setSymbol("star.fill", tintHex: "E34D59", budgetID: "budget-a", accountID: "same-account")

        #expect(store.iconsEnabled(for: "budget-a") == false)
        #expect(store.iconsEnabled(for: "budget-b") == true)
        #expect(store.customization(for: "budget-a", accountID: "same-account")?.symbolName == "star.fill")
        #expect(store.customization(for: "budget-b", accountID: "same-account") == nil)
    }

    @Test func migratesLegacyIconPreferenceToOnlyTheOpenBudget() {
        let (store, defaults, root, suite) = makeStore()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        defaults.set(false, forKey: "showAccountTypeIcons")

        #expect(store.iconsEnabled(for: "budget-a") == false)
        #expect(defaults.object(forKey: "showAccountTypeIcons.budget-a") as? Bool == false)
        #expect(defaults.object(forKey: "showAccountTypeIcons") == nil)
        #expect(store.iconsEnabled(for: "budget-b") == true)
    }

    @Test func pruningRemovedAccountDeletesOnlyItsBudgetPhoto() async {
        let (store, defaults, root, suite) = makeStore()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let photoData = makePhotoData()
        #expect(await store.setPhoto(photoData, budgetID: "budget-a", accountID: "same-account"))
        #expect(await store.setPhoto(photoData, budgetID: "budget-b", accountID: "same-account"))

        let budgetAURL = store.photoFileURL(for: "budget-a", accountID: "same-account")
        let budgetBURL = store.photoFileURL(for: "budget-b", accountID: "same-account")
        #expect(FileManager.default.fileExists(atPath: budgetAURL.path))
        #expect(FileManager.default.fileExists(atPath: budgetBURL.path))

        await store.loadImage(for: "budget-a", accountID: "same-account")
        await store.loadImage(for: "budget-b", accountID: "same-account")
        #expect(store.image(for: "budget-a", accountID: "same-account") != nil)
        #expect(store.image(for: "budget-b", accountID: "same-account") != nil)

        store.prune(accounts: [], budgetID: "budget-a")

        #expect(!FileManager.default.fileExists(atPath: budgetAURL.path))
        #expect(FileManager.default.fileExists(atPath: budgetBURL.path))
        #expect(store.customization(for: "budget-a", accountID: "same-account") == nil)
        #expect(store.customization(for: "budget-b", accountID: "same-account")?.photoFilename != nil)
        #expect(store.image(for: "budget-a", accountID: "same-account") == nil)
        #expect(store.image(for: "budget-b", accountID: "same-account") != nil)
    }

    @Test func clearingBudgetRemovesOnlyThatBudgetsIconsAndPhotos() async {
        let (store, defaults, root, suite) = makeStore()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        store.setIconsEnabled(false, for: "budget-a")
        store.setSymbol("star.fill", tintHex: "E34D59", budgetID: "budget-a", accountID: "symbol-account")
        #expect(await store.setPhoto(makePhotoData(), budgetID: "budget-a", accountID: "photo-account"))
        #expect(await store.setPhoto(makePhotoData(), budgetID: "budget-b", accountID: "photo-account"))

        store.clear(budgetID: "budget-a")

        #expect(store.iconsEnabled(for: "budget-a") == true)
        #expect(store.customization(for: "budget-a", accountID: "symbol-account") == nil)
        #expect(store.customization(for: "budget-a", accountID: "photo-account") == nil)
        #expect(store.image(for: "budget-a", accountID: "photo-account") == nil)
        #expect(!FileManager.default.fileExists(
            atPath: store.photoFileURL(for: "budget-a", accountID: "photo-account").path
        ))
        #expect(store.customization(for: "budget-b", accountID: "photo-account")?.photoFilename != nil)
        #expect(FileManager.default.fileExists(
            atPath: store.photoFileURL(for: "budget-b", accountID: "photo-account").path
        ))
    }

    @Test func choosingSymbolDeletesPreviousPhoto() async {
        let (store, defaults, root, suite) = makeStore()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        #expect(await store.setPhoto(makePhotoData(), budgetID: "budget-a", accountID: "account"))
        let photoURL = store.photoFileURL(for: "budget-a", accountID: "account")
        #expect(FileManager.default.fileExists(atPath: photoURL.path))

        store.setSymbol("car.fill", tintHex: "28A879", budgetID: "budget-a", accountID: "account")

        #expect(!FileManager.default.fileExists(atPath: photoURL.path))
        #expect(store.image(for: "budget-a", accountID: "account") == nil)
        #expect(store.customization(for: "budget-a", accountID: "account")
            == AccountIconCustomization(symbolName: "car.fill", tintHex: "28A879", photoFilename: nil))
    }

    private func makeStore() -> (AccountIconCustomizationStore, UserDefaults, URL, String) {
        let suite = "AccountIconCustomizationStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AccountIconCustomizationStore(defaults: defaults, applicationSupportDirectory: root)
        return (store, defaults, root, suite)
    }

    private func makePhotoData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 1024))
        return renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        }.pngData()!
    }
}
