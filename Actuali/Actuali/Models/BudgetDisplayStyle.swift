import Foundation

/// How the Budget tab lays out its summary and category rows (actios-96wa).
/// `clean` is the card look from the App Store screenshots — category name
/// with a large Available amount and Budgeted/Spent captions. `detailed` is
/// the PWA-style table of Budgeted/Spent/Balance pill columns.
enum BudgetDisplayStyle: String, CaseIterable {
    case clean
    case detailed
    case compact
}
