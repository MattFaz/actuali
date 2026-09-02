import Testing
@testable import Actuali

@Test func approximateScheduleAmountSeparatesTheMarkerFromTheSign() {
    #expect(ScheduleRow.formattedAmount("-1200.00", amountOp: .isApprox) == "~ -1200.00")
}
