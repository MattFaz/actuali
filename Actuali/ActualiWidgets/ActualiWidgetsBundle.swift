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
        DailyBurnRateWidget()
        SpendingComparisonWidget()
        LargestTransactionsWidget()
        OverspentAlertsWidget()
        if #available(iOS 27.0, *) {
            OverviewWidget()
        }
        QuickAddTransactionWidget()
    }
}
