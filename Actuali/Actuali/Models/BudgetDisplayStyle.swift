/// How the Budget tab lays out its summary and category rows (actios-96wa).
/// `clean` is the card look from the App Store screenshots — category name
/// with a large Available amount and Budgeted/Spent captions. `compact` adapts
/// the companion app's plain monthly table while retaining Actuali behavior.
enum BudgetDisplayStyle: String, CaseIterable {
    case clean
    case compact

    /// Detailed was removed in GH #442; keep its saved value opening Compact.
    static func resolved(from raw: String?) -> BudgetDisplayStyle {
        if raw == "detailed" { return .compact }
        return raw.flatMap(BudgetDisplayStyle.init(rawValue:)) ?? .clean
    }
}
