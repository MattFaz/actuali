import Foundation
import Testing
@testable import Actuali

/// Tests for budget category balance transfer and overspending cover functionality.
@MainActor
struct BudgetStoreBalanceTransferTests {

    @Test func coverOverspendingUsingToBudgetSucceeds() async throws {
        let store = BudgetStore.previewInstance()
        let testMonth = "2026-08"
        
        // Create a mock budget with a category in the red
        let overSpentCategory = CategoryBudget(
            month: testMonth,
            categoryId: "cat-1",
            categoryName: "Food",
            groupId: "group-1",
            groupName: "Expenses",
            groupSortOrder: 1.0,
            categorySortOrder: 1.0,
            budgeted: 10000,
            spent: -15000,
            available: -5000,
            carryover: 0
        )
        
        let budget = BudgetMonth(
            month: testMonth,
            categoryBudgets: [overSpentCategory],
            toBudget: 10000
        )
        
        store.currentBudgetMonth = budget
        
        // Cover $50 of overspending from To Budget
        try await store.coverOverspendingFromToBudget(
            categoryId: "cat-1",
            month: testMonth,
            amountCents: 5000
        )
        
        // Should call setBudgetAmount (which we can't directly test here without mocking)
        // But the logic validates that we can cover when To Budget has funds
    }

    @Test func coverOverspendingFailsWithInsufficientToBudget() async throws {
        let store = BudgetStore.previewInstance()
        let testMonth = "2026-08"
        
        let overSpentCategory = CategoryBudget(
            month: testMonth,
            categoryId: "cat-1",
            categoryName: "Food",
            groupId: "group-1",
            groupName: "Expenses",
            groupSortOrder: 1.0,
            categorySortOrder: 1.0,
            budgeted: 10000,
            spent: -15000,
            available: -5000,
            carryover: 0
        )
        
        let budget = BudgetMonth(
            month: testMonth,
            categoryBudgets: [overSpentCategory],
            toBudget: 2000  // Only $20 available
        )
        
        store.currentBudgetMonth = budget
        
        // Try to cover $50 when only $20 is available
        do {
            try await store.coverOverspendingFromToBudget(
                categoryId: "cat-1",
                month: testMonth,
                amountCents: 5000
            )
            #expect(Bool(false), "Should have thrown insufficientFunds error")
        } catch BudgetStoreError.insufficientFundsForTransfer {
            // Expected
        }
    }

    @Test func coverOverspendingFailsWithZeroAmount() async throws {
        let store = BudgetStore.previewInstance()
        let testMonth = "2026-08"
        
        let budget = BudgetMonth(month: testMonth, categoryBudgets: [], toBudget: 10000)
        store.currentBudgetMonth = budget
        
        do {
            try await store.coverOverspendingFromToBudget(
                categoryId: "cat-1",
                month: testMonth,
                amountCents: 0
            )
            #expect(Bool(false), "Should have thrown invalidTransferAmount error")
        } catch BudgetStoreError.invalidTransferAmount {
            // Expected
        }
    }

    @Test func coverOverspendingFromCategorySucceeds() async throws {
        let store = BudgetStore.previewInstance()
        let testMonth = "2026-08"
        
        let overSpentCategory = CategoryBudget(
            month: testMonth,
            categoryId: "cat-1",
            categoryName: "Food",
            groupId: "group-1",
            groupName: "Expenses",
            groupSortOrder: 1.0,
            categorySortOrder: 1.0,
            budgeted: 10000,
            spent: -15000,
            available: -5000,
            carryover: 0
        )
        
        let sourceCategory = CategoryBudget(
            month: testMonth,
            categoryId: "cat-2",
            categoryName: "Entertainment",
            groupId: "group-1",
            groupName: "Expenses",
            groupSortOrder: 1.0,
            categorySortOrder: 2.0,
            budgeted: 10000,
            spent: -2000,
            available: 8000,
            carryover: 0
        )
        
        let budget = BudgetMonth(
            month: testMonth,
            categoryBudgets: [overSpentCategory, sourceCategory],
            toBudget: 0
        )
        
        store.currentBudgetMonth = budget
        
        // Cover $30 of overspending from Entertainment's positive balance
        try await store.coverOverspendingFromCategory(
            categoryId: "cat-1",
            fromCategoryId: "cat-2",
            month: testMonth,
            amountCents: 3000
        )
        
        // The logic validates we can transfer when source has sufficient balance
    }

    @Test func coverOverspendingFromCategoryFailsWithSameCategory() async throws {
        let store = BudgetStore.previewInstance()
        let testMonth = "2026-08"
        
        let budget = BudgetMonth(month: testMonth, categoryBudgets: [], toBudget: 0)
        store.currentBudgetMonth = budget
        
        do {
            try await store.coverOverspendingFromCategory(
                categoryId: "cat-1",
                fromCategoryId: "cat-1",  // Same category!
                month: testMonth,
                amountCents: 3000
            )
            #expect(Bool(false), "Should have thrown transferSourceAndDestinationMatch error")
        } catch BudgetStoreError.transferSourceAndDestinationMatch {
            // Expected
        }
    }

    @Test func coverOverspendingFromCategoryFailsWithInsufficientBalance() async throws {
        let store = BudgetStore.previewInstance()
        let testMonth = "2026-08"
        
        let overSpentCategory = CategoryBudget(
            month: testMonth,
            categoryId: "cat-1",
            categoryName: "Food",
            groupId: "group-1",
            groupName: "Expenses",
            groupSortOrder: 1.0,
            categorySortOrder: 1.0,
            budgeted: 10000,
            spent: -15000,
            available: -5000,
            carryover: 0
        )
        
        let sourceCategory = CategoryBudget(
            month: testMonth,
            categoryId: "cat-2",
            categoryName: "Entertainment",
            groupId: "group-1",
            groupName: "Expenses",
            groupSortOrder: 1.0,
            categorySortOrder: 2.0,
            budgeted: 10000,
            spent: -9500,
            available: 500,
            carryover: 0
        )
        
        let budget = BudgetMonth(
            month: testMonth,
            categoryBudgets: [overSpentCategory, sourceCategory],
            toBudget: 0
        )
        
        store.currentBudgetMonth = budget
        
        // Try to transfer $60 when only $5 is available
        do {
            try await store.coverOverspendingFromCategory(
                categoryId: "cat-1",
                fromCategoryId: "cat-2",
                month: testMonth,
                amountCents: 6000
            )
            #expect(Bool(false), "Should have thrown insufficientFundsForTransfer error")
        } catch BudgetStoreError.insufficientFundsForTransfer {
            // Expected
        }
    }

    @Test func transferFundsSucceeds() async throws {
        let store = BudgetStore.previewInstance()
        let testMonth = "2026-08"
        
        let sourceCategory = CategoryBudget(
            month: testMonth,
            categoryId: "cat-1",
            categoryName: "Food",
            groupId: "group-1",
            groupName: "Expenses",
            groupSortOrder: 1.0,
            categorySortOrder: 1.0,
            budgeted: 10000,
            spent: -2000,
            available: 8000,
            carryover: 0
        )
        
        let destCategory = CategoryBudget(
            month: testMonth,
            categoryId: "cat-2",
            categoryName: "Entertainment",
            groupId: "group-1",
            groupName: "Expenses",
            groupSortOrder: 1.0,
            categorySortOrder: 2.0,
            budgeted: 10000,
            spent: -9000,
            available: 1000,
            carryover: 0
        )
        
        let budget = BudgetMonth(
            month: testMonth,
            categoryBudgets: [sourceCategory, destCategory],
            toBudget: 0
        )
        
        store.currentBudgetMonth = budget
        
        // Transfer $30 from Food to Entertainment
        try await store.transferFunds(
            fromCategoryId: "cat-1",
            toCategoryId: "cat-2",
            month: testMonth,
            amountCents: 3000
        )
        
        // The logic validates successful transfer when source has sufficient balance
    }

    @Test func transferFundsFailsWithSameCategory() async throws {
        let store = BudgetStore.previewInstance()
        let testMonth = "2026-08"
        
        let budget = BudgetMonth(month: testMonth, categoryBudgets: [], toBudget: 0)
        store.currentBudgetMonth = budget
        
        do {
            try await store.transferFunds(
                fromCategoryId: "cat-1",
                toCategoryId: "cat-1",  // Same category!
                month: testMonth,
                amountCents: 3000
            )
            #expect(Bool(false), "Should have thrown transferSourceAndDestinationMatch error")
        } catch BudgetStoreError.transferSourceAndDestinationMatch {
            // Expected
        }
    }

    @Test func transferFundsFailsWithInsufficientBalance() async throws {
        let store = BudgetStore.previewInstance()
        let testMonth = "2026-08"
        
        let sourceCategory = CategoryBudget(
            month: testMonth,
            categoryId: "cat-1",
            categoryName: "Food",
            groupId: "group-1",
            groupName: "Expenses",
            groupSortOrder: 1.0,
            categorySortOrder: 1.0,
            budgeted: 10000,
            spent: -9500,
            available: 500,
            carryover: 0
        )
        
        let destCategory = CategoryBudget(
            month: testMonth,
            categoryId: "cat-2",
            categoryName: "Entertainment",
            groupId: "group-1",
            groupName: "Expenses",
            groupSortOrder: 1.0,
            categorySortOrder: 2.0,
            budgeted: 10000,
            spent: -5000,
            available: 5000,
            carryover: 0
        )
        
        let budget = BudgetMonth(
            month: testMonth,
            categoryBudgets: [sourceCategory, destCategory],
            toBudget: 0
        )
        
        store.currentBudgetMonth = budget
        
        // Try to transfer $60 when only $5 is available
        do {
            try await store.transferFunds(
                fromCategoryId: "cat-1",
                toCategoryId: "cat-2",
                month: testMonth,
                amountCents: 6000
            )
            #expect(Bool(false), "Should have thrown insufficientFundsForTransfer error")
        } catch BudgetStoreError.insufficientFundsForTransfer {
            // Expected
        }
    }

    @Test func transferFundsFailsWithZeroAmount() async throws {
        let store = BudgetStore.previewInstance()
        let testMonth = "2026-08"
        
        let budget = BudgetMonth(month: testMonth, categoryBudgets: [], toBudget: 0)
        store.currentBudgetMonth = budget
        
        do {
            try await store.transferFunds(
                fromCategoryId: "cat-1",
                toCategoryId: "cat-2",
                month: testMonth,
                amountCents: 0
            )
            #expect(Bool(false), "Should have thrown invalidTransferAmount error")
        } catch BudgetStoreError.invalidTransferAmount {
            // Expected
        }
    }

    @Test func partialTransferAllowed() async throws {
        let store = BudgetStore.previewInstance()
        let testMonth = "2026-08"
        
        let sourceCategory = CategoryBudget(
            month: testMonth,
            categoryId: "cat-1",
            categoryName: "Food",
            groupId: "group-1",
            groupName: "Expenses",
            groupSortOrder: 1.0,
            categorySortOrder: 1.0,
            budgeted: 10000,
            spent: -2000,
            available: 8000,
            carryover: 0
        )
        
        let destCategory = CategoryBudget(
            month: testMonth,
            categoryId: "cat-2",
            categoryName: "Entertainment",
            groupId: "group-1",
            groupName: "Expenses",
            groupSortOrder: 1.0,
            categorySortOrder: 2.0,
            budgeted: 10000,
            spent: -9000,
            available: 1000,
            carryover: 0
        )
        
        let budget = BudgetMonth(
            month: testMonth,
            categoryBudgets: [sourceCategory, destCategory],
            toBudget: 0
        )
        
        store.currentBudgetMonth = budget
        
        // Transfer $20 of $80 available from Food
        try await store.transferFunds(
            fromCategoryId: "cat-1",
            toCategoryId: "cat-2",
            month: testMonth,
            amountCents: 2000
        )
        
        // Should succeed: $2000 is less than $8000 available
    }

    // MARK: - Tests for positive balance transfer (TransferFundsSheet)
    
    /// Verifies that transferring full positive balance succeeds
    @Test func transferFullPositiveBalanceSucceeds() async throws {
        let store = BudgetStore.previewInstance()
        let testMonth = "2026-08"
        
        let sourceCategory = CategoryBudget(
            month: testMonth,
            categoryId: "cat-1",
            categoryName: "Food",
            groupId: "group-1",
            groupName: "Expenses",
            groupSortOrder: 1.0,
            categorySortOrder: 1.0,
            budgeted: 15000,
            spent: -2000,
            available: 13000,  // Positive balance
            carryover: 0
        )
        
        let destCategory = CategoryBudget(
            month: testMonth,
            categoryId: "cat-2",
            categoryName: "Entertainment",
            groupId: "group-1",
            groupName: "Expenses",
            groupSortOrder: 1.0,
            categorySortOrder: 2.0,
            budgeted: 5000,
            spent: -3000,
            available: 2000,
            carryover: 0
        )
        
        let budget = BudgetMonth(
            month: testMonth,
            categoryBudgets: [sourceCategory, destCategory],
            toBudget: 0
        )
        
        store.currentBudgetMonth = budget
        
        // Transfer entire positive balance from Food to Entertainment
        try await store.transferFunds(
            fromCategoryId: "cat-1",
            toCategoryId: "cat-2",
            month: testMonth,
            amountCents: 13000
        )
        
        // Should succeed: source has exactly $130 available
    }
    
    /// Verifies that transferring partial positive balance succeeds
    @Test func transferPartialPositiveBalanceSucceeds() async throws {
        let store = BudgetStore.previewInstance()
        let testMonth = "2026-08"
        
        let sourceCategory = CategoryBudget(
            month: testMonth,
            categoryId: "cat-1",
            categoryName: "Food",
            groupId: "group-1",
            groupName: "Expenses",
            groupSortOrder: 1.0,
            categorySortOrder: 1.0,
            budgeted: 15000,
            spent: -2000,
            available: 13000,  // Positive balance
            carryover: 0
        )
        
        let destCategory = CategoryBudget(
            month: testMonth,
            categoryId: "cat-2",
            categoryName: "Entertainment",
            groupId: "group-1",
            groupName: "Expenses",
            groupSortOrder: 1.0,
            categorySortOrder: 2.0,
            budgeted: 5000,
            spent: -3000,
            available: 2000,
            carryover: 0
        )
        
        let budget = BudgetMonth(
            month: testMonth,
            categoryBudgets: [sourceCategory, destCategory],
            toBudget: 0
        )
        
        store.currentBudgetMonth = budget
        
        // Transfer $50 of $130 available from Food to Entertainment
        try await store.transferFunds(
            fromCategoryId: "cat-1",
            toCategoryId: "cat-2",
            month: testMonth,
            amountCents: 5000
        )
        
        // Should succeed: $50 < $130 available
    }
    
    /// Verifies that positive balance exceeding transfer amount fails correctly
    @Test func transferPositiveBalanceExceedingAmountFails() async throws {
        let store = BudgetStore.previewInstance()
        let testMonth = "2026-08"
        
        let sourceCategory = CategoryBudget(
            month: testMonth,
            categoryId: "cat-1",
            categoryName: "Food",
            groupId: "group-1",
            groupName: "Expenses",
            groupSortOrder: 1.0,
            categorySortOrder: 1.0,
            budgeted: 15000,
            spent: -2000,
            available: 13000,  // Positive balance
            carryover: 0
        )
        
        let destCategory = CategoryBudget(
            month: testMonth,
            categoryId: "cat-2",
            categoryName: "Entertainment",
            groupId: "group-1",
            groupName: "Expenses",
            groupSortOrder: 1.0,
            categorySortOrder: 2.0,
            budgeted: 5000,
            spent: -3000,
            available: 2000,
            carryover: 0
        )
        
        let budget = BudgetMonth(
            month: testMonth,
            categoryBudgets: [sourceCategory, destCategory],
            toBudget: 0
        )
        
        store.currentBudgetMonth = budget
        
        // Try to transfer $200 when only $130 is available
        do {
            try await store.transferFunds(
                fromCategoryId: "cat-1",
                toCategoryId: "cat-2",
                month: testMonth,
                amountCents: 20000
            )
            #expect(Bool(false), "Should have thrown insufficientFundsForTransfer error")
        } catch BudgetStoreError.insufficientFundsForTransfer {
            // Expected
        }
    }
}
