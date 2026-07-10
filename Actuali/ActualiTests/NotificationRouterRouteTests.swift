import Foundation
import Testing
@testable import Actuali

@MainActor
struct NotificationRouterRouteTests {

    @Test func successMarkerSetsNavigationFlagOnly() {
        let router = NotificationRouter()
        router.route(userInfo: TransactionLoggedMarker.userInfo)
        #expect(router.pendingAllAccountsNavigation)
        #expect(router.pendingPrefill == nil)
    }

    @Test func prefillPayloadSetsPrefillOnly() {
        let router = NotificationRouter()
        let prefill = TransactionPrefill(
            accountId: "acct-1",
            payee: "Blue Bottle",
            amountCents: 450,
            date: Date(timeIntervalSince1970: 1_750_000_000)
        )
        router.route(userInfo: prefill.userInfo)
        #expect(router.pendingPrefill == prefill)
        #expect(router.pendingAllAccountsNavigation == false)
    }

    @Test func junkUserInfoSetsNeither() {
        let router = NotificationRouter()
        router.route(userInfo: [:])
        router.route(userInfo: ["kind": "com.mfazz.Actuali.somethingElse"])
        router.route(userInfo: ["unrelated": true])
        #expect(router.pendingPrefill == nil)
        #expect(router.pendingAllAccountsNavigation == false)
    }
}
