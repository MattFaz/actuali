import Foundation
import Testing
@testable import Actuali

struct SchedulesListLocalizationTests {
    private let appBundle = Bundle(identifier: "com.mfazz.ActualiOS")!

    @Test(arguments: [
        (0, "0 completed schedules hidden.", "0 programmation terminée masquée.", "0 agendamento concluído oculto."),
        (1, "1 completed schedule hidden.", "1 programmation terminée masquée.", "1 agendamento concluído oculto."),
        (2, "2 completed schedules hidden.", "2 programmations terminées masquées.", "2 agendamentos concluídos ocultos.")
    ])
    func completedFooterUsesCLDRPluralForms(
        count: Int, english: String, french: String, brazilianPortuguese: String
    ) {
        #expect(SchedulesListLocalization.completedFooter(
            count: count, locale: Locale(identifier: "en_US"), bundle: appBundle) == english)
        #expect(SchedulesListLocalization.completedFooter(
            count: count, locale: Locale(identifier: "fr_FR"), bundle: appBundle) == french)
        #expect(SchedulesListLocalization.completedFooter(
            count: count, locale: Locale(identifier: "pt_BR"), bundle: appBundle) == brazilianPortuguese)
    }
}

@Test func approximateScheduleAmountSeparatesTheMarkerFromTheSign() {
    #expect(ScheduleRow.formattedAmount("-1200.00", amountOp: .isApprox) == "~ -1200.00")
}
