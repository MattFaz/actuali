import Foundation

struct Category: Identifiable, Hashable {
    let id: String
    var name: String
    var groupId: String
    var isIncome: Bool
    var hidden: Bool
    var sortOrder: Double
}

struct CategoryGroup: Identifiable, Hashable {
    let id: String
    var name: String
    var isIncome: Bool
    var hidden: Bool
    var sortOrder: Double
    var categories: [Category]
}


// MARK: - CRDTSyncable

extension Category: CRDTSyncable {
    static var datasetName: String { "categories" }

    /// The columns upstream's `insertCategory` writes. Goal templates
    /// (`goal_def`) and note cleanups (`cleanup_def`) stay untouched — the
    /// PWA leaves them null on a fresh category too.
    var syncableFields: [String: Any?] {
        [
            "name": name,
            "cat_group": groupId,
            "is_income": isIncome ? 1 : 0,
            "hidden": hidden ? 1 : 0,
            "tombstone": 0,
            "sort_order": sortOrder
        ]
    }
}

extension CategoryGroup: CRDTSyncable {
    static var datasetName: String { "category_groups" }

    /// `categories` is the assembled child list, not a column — the rows it
    /// holds sync as their own `categories` messages.
    var syncableFields: [String: Any?] {
        [
            "name": name,
            "is_income": isIncome ? 1 : 0,
            "hidden": hidden ? 1 : 0,
            "tombstone": 0,
            "sort_order": sortOrder
        ]
    }
}

// MARK: - Category Mapping

/// Points a category id at the category its transactions should resolve to —
/// itself for a fresh category, the survivor once a category is merged away.
/// Every read path joins through this table, so upstream's `insertCategory`
/// writes the self-mapping row alongside the category itself, the same pair
/// `payee_mapping` gets.
struct CategoryMapping: Identifiable, Hashable {
    let id: String
    let targetId: String
}

extension CategoryMapping: CRDTSyncable {
    static var datasetName: String { "category_mapping" }

    var syncableFields: [String: Any?] {
        [
            "transferId": targetId
        ]
    }
}
