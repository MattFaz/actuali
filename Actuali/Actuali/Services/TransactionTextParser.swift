import Foundation
import NaturalLanguage
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "TransactionTextParser")

/// Result of parsing a bank SMS / message into transaction fields.
struct ParsedMessage {
    var amount: Double?
    var payee: String?
    var cardHint: String?
    var date: Date?
    var isIncome: Bool
    var rawText: String

    func toPendingImport() -> PendingImport {
        PendingImport(
            amount: amount,
            payee: payee,
            cardHint: cardHint,
            date: date ?? Date(),
            isIncome: isIncome,
            rawText: rawText
        )
    }
}

// MARK: - Foundation Models structured output

#if canImport(FoundationModels)
@available(iOS 26, *)
@Generable
struct ExtractedTransaction {
    @Guide(description: "The transaction amount as a positive decimal number, without currency symbol")
    var amount: Double

    @Guide(description: "The merchant or payee name")
    var payee: String

    @Guide(description: "Last 4 digits of the card or account number, if mentioned")
    var cardHint: String?

    @Guide(description: "Whether money was received or credited (true) or spent or debited (false)")
    var isIncome: Bool
}
#endif

// MARK: - Parser

enum TransactionTextParser {

    /// Parse raw message text into transaction fields. Uses Foundation Models
    /// (on-device LLM) when available, falls back to NSDataDetector + NLTagger.
    static func parse(_ text: String) async -> ParsedMessage {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            // ponytail: Foundation Models availability is a runtime check —
            // model may not be downloaded yet or device may lack Apple Intelligence.
            let model = SystemLanguageModel.default
            if model.availability == .available {
                do {
                    return try await parseWithFoundationModels(text)
                } catch {
                    logger.warning("Foundation Models parse failed, falling back: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        #endif
        return parseWithFallback(text)
    }

    // MARK: - Foundation Models path

    #if canImport(FoundationModels)
    @available(iOS 26, *)
    private static func parseWithFoundationModels(_ text: String) async throws -> ParsedMessage {
        let session = LanguageModelSession(instructions: """
            Extract transaction details from bank notification text. \
            The amount should be a positive number without currency symbols. \
            Identify the merchant or payee name. \
            If a card or account number's last 4 digits are mentioned, extract them. \
            Determine if money was received (income/credit/refund) or spent (debit/payment).
            """)
        let response = try await session.respond(
            to: text,
            generating: ExtractedTransaction.self
        )
        let extracted = response.content
        let date = extractDate(from: text)
        return ParsedMessage(
            amount: extracted.amount,
            payee: extracted.payee.isEmpty ? nil : extracted.payee,
            cardHint: extracted.cardHint,
            date: date,
            isIncome: extracted.isIncome,
            rawText: text
        )
    }
    #endif

    // MARK: - Fallback path (NSDataDetector + NLTagger + AmountParser)

    private static func parseWithFallback(_ text: String) -> ParsedMessage {
        let lower = text.lowercased()
        let isIncome = lower.contains("credited")
            || lower.contains("received")
            || lower.contains("refund")

        return ParsedMessage(
            amount: extractAmount(from: text),
            payee: extractMerchant(from: text),
            cardHint: extractCardHint(from: text),
            date: extractDate(from: text),
            isIncome: isIncome,
            rawText: text
        )
    }

    // MARK: - Extraction helpers

    /// Extract the first currency amount found. Delegates to AmountParser for
    /// locale-aware parsing, but first isolates a currency-adjacent token.
    private static func extractAmount(from text: String) -> Double? {
        // Try AmountParser on the full text first — it already handles
        // single-number strings like "$15.50" or "500.00".
        if let parsed = AmountParser.parse(text), parsed > 0 {
            return parsed
        }
        // ponytail: if AmountParser fails (multiple numbers in text), try
        // extracting the first currency-adjacent number. Upgrade path:
        // per-locale currency regex table.
        let pattern = #"[\$€£₹]?\s*(\d[\d,]*\.?\d*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return AmountParser.parse(String(text[range]))
    }

    /// Extract the last 4 digits of a card / account number.
    private static func extractCardHint(from text: String) -> String? {
        // ponytail: simple pattern covering "card ending 1234", "XX9876",
        // "A/C ...4321", "a/c no 1234". Upgrade path: broader pattern set.
        let pattern = #"(?:card|a/c|ending|acct|xx|x{2,})[^\d]*(\d{4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    /// Extract the first date found via NSDataDetector.
    private static func extractDate(from text: String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.first?.date
    }

    /// Extract a merchant / payee name. Tries keyword patterns first
    /// ("at <Merchant>", "to <Merchant>"), falls back to NLTagger NER.
    private static func extractMerchant(from text: String) -> String? {
        // Keyword-based extraction for common bank SMS patterns.
        let pattern = #"(?:at|to|paid|merchant|vpa)\s+([A-Za-z0-9\s&'.]+?)(?:\s+(?:on|using|via|for|with|card|ref|\.|\,)|$)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            let candidate = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty { return candidate }
        }

        // NLTagger fallback: find the first organization name.
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var found: String?
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitPunctuation, .omitWhitespace, .joinNames]
        ) { tag, range in
            if tag == .organizationName {
                found = String(text[range])
                return false
            }
            return true
        }
        return found
    }
}
