import AppIntents
import Testing
@testable import Actuali

struct LogTransactionIntentTests {

    @Test func silentByDefaultSoAutomationsDoNotShowADialog() {
        let result = LogTransactionIntent.result(dialogText: "Logged $4.50 at Blue Bottle", showConfirmation: false)
        #expect(result.dialog == nil)
    }

    @Test func speaksWhenTheCallerAsksFor() {
        let result = LogTransactionIntent.result(dialogText: "Logged $4.50 at Blue Bottle", showConfirmation: true)
        #expect(result.dialog != nil)
    }

    private var appBundle: Bundle {
        Bundle(identifier: "com.mfazz.ActualiOS")!
    }

    @Test func siriShortcutOptsIntoTheSpokenConfirmation() {
        #expect(LogTransactionIntent(showConfirmation: true).showConfirmation)
        #expect(LogTransactionIntent().showConfirmation == false)
    }

    @Test func errorsUseRequestedLocaleAndTypedDetails() {
        let cases: [(Locale, String, String)] = [
            (Locale(identifier: "en_US"), "Amount must be greater than 0 (received \"12\").", "Couldn't save transaction. Tap to retry. (disk full)"),
            (Locale(identifier: "fr_FR"), "Le montant doit être supérieur à 0 (valeur reçue : \"12\").", "Impossible d'enregistrer la transaction. Touchez pour réessayer. (disk full)"),
            (Locale(identifier: "pt_BR"), "O valor deve ser maior que 0 (valor recebido: \"12\").", "Não foi possível salvar a transação. Toque para tentar novamente. (disk full)")
        ]

        for (locale, invalidAmount, writeFailed) in cases {
            #expect(LogTransactionError.localizedString(
                for: .invalidAmount(received: " 12 "), locale: locale, bundle: appBundle
            ) == invalidAmount)
            #expect(LogTransactionError.localizedString(
                for: .writeFailed(underlying: "disk full"), locale: locale, bundle: appBundle
            ) == writeFailed)
        }

        let error = LogTransactionError.invalidAmount(received: "12")
        #expect(error.errorDescription == String(localized: error.localizedStringResource))
    }

    @Test func balanceErrorsUseRequestedLocale() {
        let expected: [(Locale, String)] = [
            (Locale(identifier: "en_US"), "Account was not found. Select a valid account in your shortcut."),
            (Locale(identifier: "fr_FR"), "Compte introuvable. Sélectionnez un compte valide dans votre raccourci."),
            (Locale(identifier: "pt_BR"), "A conta não foi encontrada. Selecione uma conta válida no atalho.")
        ]

        for (locale, value) in expected {
            #expect(GetBalanceError.localizedString(for: .accountNotFound, locale: locale, bundle: appBundle) == value)
        }
    }

    @Test func dialogFormatterPreservesAmountThenPayeePlaceholderOrder() {
        let cases = [
            ("en_US", true, "AMOUNT", "PAYEE", "Logged AMOUNT at PAYEE"),
            ("fr_FR", true, "AMOUNT", "PAYEE", "Transaction de AMOUNT chez PAYEE enregistrée"),
            ("pt_BR", true, "AMOUNT", "PAYEE", "Transação de AMOUNT em PAYEE registrada"),
            ("en_US", false, "AMOUNT", "PAYEE", "Saved locally: AMOUNT at PAYEE"),
            ("fr_FR", false, "AMOUNT", "PAYEE", "Enregistrée localement : AMOUNT chez PAYEE"),
            ("pt_BR", false, "AMOUNT", "PAYEE", "Salva localmente: AMOUNT em PAYEE"),
            ("en_US", true, "AMOUNT", "", "Logged AMOUNT"),
            ("fr_FR", false, "AMOUNT", "", "Enregistrée localement : AMOUNT")
        ]

        for (localeIdentifier, synced, amount, payee, expected) in cases {
            #expect(LogTransactionDialogFormatter.string(
                amount: amount,
                payee: payee,
                synced: synced,
                locale: Locale(identifier: localeIdentifier),
                bundle: appBundle
            ) == expected)
        }
    }
}
