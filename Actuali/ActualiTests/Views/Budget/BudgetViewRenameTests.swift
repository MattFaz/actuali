import Testing
@testable import Actuali

struct BudgetViewRenameTests {
    @Test(arguments: ["", " ", "\t\n", " \r\n "])
    func blankDraftHasNoRenameName(_ draft: String) {
        #expect(BudgetView.renameName(draft) == nil)
    }

    @Test(arguments: ["Food", "  Food  ", "\nFood\t"])
    func renameNameTrimsSurroundingWhitespace(_ draft: String) {
        #expect(BudgetView.renameName(draft) == "Food")
    }

    @Test func renameNamePreservesInternalWhitespace() {
        #expect(BudgetView.renameName("  Dining Out  ") == "Dining Out")
    }
}
