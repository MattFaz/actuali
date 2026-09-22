import Foundation
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreTagTests {
    private let appBundle = Bundle(identifier: "com.mfazz.ActualiOS")!

    @Test func createTagRejectsEmptyOrInvalidName() async {
        let store = BudgetStore.previewInstance()
        await #expect(throws: BudgetStoreError.invalidTagName) {
            try await store.createTag(name: "")
        }
        await #expect(throws: BudgetStoreError.invalidTagName) {
            try await store.createTag(name: "   ")
        }
        await #expect(throws: BudgetStoreError.invalidTagName) {
            try await store.createTag(name: "has spaces")
        }
        await #expect(throws: BudgetStoreError.invalidTagName) {
            try await store.createTag(name: "#")
        }
    }

    @Test func createTagRejectsDuplicateNameIgnoringCase() async {
        let store = BudgetStore.previewInstance()
        store.tags = [Tag(id: "t1", tag: "vacation")]
        await #expect(throws: BudgetStoreError.tagAlreadyExists) {
            try await store.createTag(name: "VACATION")
        }
        await #expect(throws: BudgetStoreError.tagAlreadyExists) {
            try await store.createTag(name: "#vacation")
        }
    }

    @Test func renameTagRejectsInvalidOrDuplicateName() async {
        let store = BudgetStore.previewInstance()
        store.tags = [
            Tag(id: "t1", tag: "vacation"),
            Tag(id: "t2", tag: "travel"),
        ]
        await #expect(throws: BudgetStoreError.invalidTagName) {
            try await store.renameTag(id: "t1", oldName: "vacation", newName: "invalid name")
        }
        await #expect(throws: BudgetStoreError.tagAlreadyExists) {
            try await store.renameTag(id: "t1", oldName: "vacation", newName: "TRAVEL")
        }
    }

    @Test func tagOperationsRequireConfiguredSync() async {
        let store = BudgetStore.previewInstance()
        await #expect(throws: BudgetStoreError.syncNotConfigured) {
            try await store.createTag(name: "newtag")
        }
        await #expect(throws: BudgetStoreError.syncNotConfigured) {
            try await store.updateTag(Tag(id: "t1", tag: "vacation"))
        }
        await #expect(throws: BudgetStoreError.syncNotConfigured) {
            try await store.deleteTag(id: "t1")
        }
        await #expect(throws: BudgetStoreError.syncNotConfigured) {
            try await store.renameTag(id: "t1", oldName: "vacation", newName: "holiday")
        }
        await #expect(throws: BudgetStoreError.syncNotConfigured) {
            try await store.discoverTags()
        }
    }

    @Test func tagsByNameDictionaryUpdatesOnTagChange() {
        let store = BudgetStore.previewInstance()
        store.tags = [
            Tag(id: "t1", tag: "Vacation"),
            Tag(id: "t2", tag: "Food"),
        ]
        #expect(store.tagsByName["vacation"]?.id == "t1")
        #expect(store.tagsByName["food"]?.id == "t2")
        #expect(store.tagsByName["other"] == nil)
    }

    @Test func errorMessagesLocalizeCorrectly() {
        let enLocale = Locale(identifier: "en_US")
        #expect(BudgetStoreError.invalidTagName.message(locale: enLocale, bundle: appBundle) == "Invalid tag name")
        #expect(BudgetStoreError.tagAlreadyExists.message(locale: enLocale, bundle: appBundle) == "A tag with this name already exists")
        #expect(BudgetStoreError.tagCreationFailed("disk full").message(locale: enLocale, bundle: appBundle) == "Failed to create tag: disk full")
        #expect(BudgetStoreError.tagUpdateFailed("db error").message(locale: enLocale, bundle: appBundle) == "Failed to update tag: db error")
    }
}
