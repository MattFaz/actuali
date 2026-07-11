import Foundation

/// One row of the `custom_reports` table, as consumed by CustomReportEngine.
/// String-typed option fields deliberately mirror upstream's stored values
/// ("Payment", "Monthly", "BarGraph", …) so unsupported ones can be named in
/// fallback cards instead of failing to decode.
struct CustomReportConfig: Equatable {
    var id: String
    var name: String
    var mode: String          // "total" | "time"
    var groupBy: String       // "Category" | "Group" | "Interval" | "Payee" | ...
    var balanceType: String   // "Payment" | "Deposit" | "Net" | ...
    var interval: String      // "Daily" | "Weekly" | "Monthly" | "Yearly"
    var graphType: String     // "BarGraph" | "StackedBarGraph" | "TableGraph" | ...
    var dateRange: String?    // "All time", "Year to date", ... (dynamic ranges)
    var dateStatic: Bool
    var startDate: String?    // "yyyy-MM-dd" (used when dateStatic)
    var endDate: String?
    var includeCurrent: Bool
    var showEmpty: Bool
    var showOffBudget: Bool
    var showHidden: Bool
    var showUncategorized: Bool
    var sortBy: String        // "desc" | "asc" | "name" | "budget"
    var conditions: [WidgetRuleCondition]?
    var conditionsOp: String?
}
