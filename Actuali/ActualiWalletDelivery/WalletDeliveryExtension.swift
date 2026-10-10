import BackgroundTasks
import ExtensionFoundation
import FinanceKit

/// FinanceKit wakes this extension when Wallet data changes (at most hourly,
/// as enabled by the app). It only records the delivery and asks iOS to run
/// the app's background refresh — see `WalletDelivery` for why the sync
/// itself stays in the app.
@main
final class WalletDeliveryExtension: BackgroundDeliveryExtension {
    required init() {}

    func didReceiveData(for _: [FinanceStore.BackgroundDataType]) async {
        WalletDelivery.shared()?.requestRefresh { try BGTaskScheduler.shared.submit($0) }
    }

    func willTerminate() async {}
}
