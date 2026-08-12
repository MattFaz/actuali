import Foundation

struct Category: Identifiable, Hashable {
    let id: String
    var name: String
    var groupId: String
    var isIncome: Bool
    var hidden: Bool
    var sortOrder: Int
}

struct CategoryGroup: Identifiable, Hashable {
    let id: String
    var name: String
    var isIncome: Bool
    var hidden: Bool
    var sortOrder: Int
    var categories: [Category]
}
