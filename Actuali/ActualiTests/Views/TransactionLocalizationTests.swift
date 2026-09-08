import Foundation
import Testing
@testable import Actuali

struct TransactionLocalizationTests {

    private let appBundle = Bundle(identifier: "com.mfazz.ActualiOS")!

    @Test func transactionFallbackLabelsMatchTheAppCatalog() {
        let expected: [String: [String]] = [
            "Unknown Account": ["Unknown Account", "Compte inconnu", "Conta desconhecida"],
            "Off budget": ["Off budget", "Hors budget", "Fora do orçamento"],
            "Uncategorized": ["Uncategorized", "Sans catégorie", "Sem categoria"],
            "Transfer": ["Transfer", "Virement", "Transferência"],
            "Split": ["Split", "Ventilation", "Divisão"],
            "No payee": ["No payee", "Sans bénéficiaire", "Sem beneficiário"],
            "Unknown": ["Unknown", "Inconnu", "Desconhecido"],
            "Cleared": ["Cleared", "Pointée", "Compensado"],
            "Reconciled": ["Reconciled", "Rapproché", "Conciliado"],
            "Uncleared": ["Uncleared", "Non pointée", "Não compensado"],
            "Outflow": ["Outflow", "Sortie", "Saída"],
            "Inflow": ["Inflow", "Entrée", "Entrada"],
            "Payee (optional)": ["Payee (optional)", "Bénéficiaire (facultatif)", "Beneficiário (opcional)"],
            "Notes (optional)": ["Notes (optional)", "Notes (facultatif)", "Notas (opcional)"]
        ]

        for (index, localeIdentifier) in ["en_US", "fr_FR", "pt_BR"].enumerated() {
            let locale = Locale(identifier: localeIdentifier)
            for (key, values) in expected {
                #expect(TransactionsListLocalization.text(
                    key,
                    locale: locale,
                    bundle: appBundle
                ) == values[index])
            }
        }
    }

    @Test func transactionStatusFallbacksUseTheRequestedLocale() {
        let expected = [
            (Locale(identifier: "en_US"), ["Cleared", "Reconciled", "Uncleared"]),
            (Locale(identifier: "fr_FR"), ["Pointée", "Rapproché", "Non pointée"]),
            (Locale(identifier: "pt_BR"), ["Compensado", "Conciliado", "Não compensado"])
        ]

        for (locale, values) in expected {
            #expect(TransactionsListLocalization.statusLabel(cleared: true, reconciled: false, locale: locale, bundle: appBundle) == values[0])
            #expect(TransactionsListLocalization.statusLabel(cleared: true, reconciled: true, locale: locale, bundle: appBundle) == values[1])
            #expect(TransactionsListLocalization.statusLabel(cleared: false, reconciled: false, locale: locale, bundle: appBundle) == values[2])
        }
    }

    @Test func transactionSelectionLabelsUseTheRequestedLocale() {
        let expected = [
            (Locale(identifier: "en_US"), ["Selected", "Not selected"]),
            (Locale(identifier: "fr_FR"), ["Sélectionnées", "Non sélectionné"])
        ]

        for (locale, values) in expected {
            #expect(TransactionsListLocalization.selectionLabel(
                isSelected: true,
                locale: locale,
                bundle: appBundle
            ) == values[0])
            #expect(TransactionsListLocalization.selectionLabel(
                isSelected: false,
                locale: locale,
                bundle: appBundle
            ) == values[1])
        }
    }

    @Test(arguments: [
        (0, "Duplicate 0 selected transactions", "Dupliquer la transaction sélectionnée (0)", "Duplicar a transação selecionada (0)"),
        (1, "Duplicate 1 selected transaction", "Dupliquer la transaction sélectionnée (1)", "Duplicar a transação selecionada (1)"),
        (2, "Duplicate 2 selected transactions", "Dupliquer les transactions sélectionnées (2)", "Duplicar as transações selecionadas (2)")
    ])
    func transactionBulkLabelsUseCLDRPluralForms(
        count: Int, english: String, french: String, brazilianPortuguese: String
    ) {
        #expect(TransactionBulkActionLocalization.duplicateLabel(
            count: count, locale: Locale(identifier: "en_US"), bundle: appBundle) == english)
        #expect(TransactionBulkActionLocalization.duplicateLabel(
            count: count, locale: Locale(identifier: "fr_FR"), bundle: appBundle) == french)
        #expect(TransactionBulkActionLocalization.duplicateLabel(
            count: count, locale: Locale(identifier: "pt_BR"), bundle: appBundle) == brazilianPortuguese)
        #expect(TransactionBulkActionLocalization.deleteLabel(
            count: count, locale: Locale(identifier: "en_US"), bundle: appBundle) == english.replacingOccurrences(of: "Duplicate", with: "Delete"))
        #expect(TransactionBulkActionLocalization.deleteLabel(
            count: count, locale: Locale(identifier: "fr_FR"), bundle: appBundle) == french.replacingOccurrences(of: "Dupliquer", with: "Supprimer"))
        #expect(TransactionBulkActionLocalization.deleteLabel(
            count: count, locale: Locale(identifier: "pt_BR"), bundle: appBundle) == brazilianPortuguese.replacingOccurrences(of: "Duplicar", with: "Excluir"))
    }

    @Test(arguments: [
        (0, "Delete 0 transactions?", "Supprimer 0 transaction ?", "Excluir 0 transação?"),
        (1, "Delete 1 transaction?", "Supprimer 1 transaction ?", "Excluir 1 transação?"),
        (2, "Delete 2 transactions?", "Supprimer 2 transactions ?", "Excluir 2 transações?")
    ])
    func transactionBulkConfirmationsUseCLDRPluralForms(
        count: Int, english: String, french: String, brazilianPortuguese: String
    ) {
        #expect(TransactionBulkActionLocalization.deleteConfirmationTitle(
            count: count, locale: Locale(identifier: "en_US"), bundle: appBundle) == english)
        #expect(TransactionBulkActionLocalization.deleteConfirmationTitle(
            count: count, locale: Locale(identifier: "fr_FR"), bundle: appBundle) == french)
        #expect(TransactionBulkActionLocalization.deleteConfirmationTitle(
            count: count, locale: Locale(identifier: "pt_BR"), bundle: appBundle) == brazilianPortuguese)
    }

    @Test func ruleOperatorsMatchTheAppCatalog() {
        let expected = [
            ("en_US", "is", "is"),
            ("fr_FR", "is", "est"),
            ("pt_BR", "is", "é"),
            ("en_US", "isNot", "is not"),
            ("fr_FR", "isNot", "n’est pas"),
            ("pt_BR", "isNot", "não é"),
            ("en_US", "gt", "is greater than"),
            ("fr_FR", "gt", "est supérieur à"),
            ("pt_BR", "gt", "é maior que")
        ]

        for (localeIdentifier, key, expectedValue) in expected {
            let resourceKey = "rule.op.\(key == "isNot" ? "isNot" : key == "gt" ? "isGreaterThan" : key)"
            #expect(ReportStrings.text(
                resourceKey,
                locale: Locale(identifier: localeIdentifier),
                bundle: appBundle
            ) == expectedValue)
        }
    }
}
