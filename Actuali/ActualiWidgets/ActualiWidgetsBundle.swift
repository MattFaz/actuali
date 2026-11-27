import SwiftUI
import WidgetKit

@main
struct ActualiWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CategoryBalanceWidget()
        AccountBalanceWidget()
        NetWorthWidget()
        ToBeBudgetedWidget()
        UpcomingBillsWidget()
        SpendingSummaryWidget()
        RecentTransactionsWidget()
        TopSpendingWidget()
        LargestTransactionsWidget()
        OverspentAlertsWidget()
        QuickAddTransactionWidget()
    }
}
