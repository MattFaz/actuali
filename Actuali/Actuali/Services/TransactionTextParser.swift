import Foundation
import NaturalLanguage
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "TransactionTextParser")

/// Result of parsing a bank SMS / message into transaction fields.
struct ParsedMessage: Equatable {
    var amount: Double?
    var sourceCurrencyCode: String?
    var payee: String?
    var cardHint: String?
    var date: Date?
    var isIncome: Bool
    var rawText: String

    func toPendingImport(originBudgetId: String? = nil) -> PendingImport {
        PendingImport(
            originBudgetId: originBudgetId,
            amount: amount,
            sourceCurrencyCode: sourceCurrencyCode,
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

    @Guide(description: "The explicit ISO 4217 source currency code, if clearly present; otherwise nil")
    var sourceCurrencyCode: String?

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
            Preserve an explicit source currency code such as USD, EUR, GBP, or INR when present; use nil when absent or ambiguous. \
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
            sourceCurrencyCode: normalizeCurrencyCode(extracted.sourceCurrencyCode),
            payee: extracted.payee.isEmpty ? nil : extracted.payee,
            cardHint: extracted.cardHint,
            date: date,
            isIncome: extracted.isIncome,
            rawText: text
        )
    }
    #endif

    // MARK: - Fallback path (NSDataDetector + NLTagger + AmountParser)

    /// Deterministic fallback parser using regex, NSDataDetector, and NLTagger.
    /// Internal so unit tests can test this path directly.
    static func parseWithFallback(_ text: String) -> ParsedMessage {
        let lower = text.lowercased()
        let isIncome = lower.contains("credited")
            || lower.contains("received")
            || lower.contains("refund")

        return ParsedMessage(
            amount: extractAmount(from: text),
            sourceCurrencyCode: extractCurrencyCode(from: text),
            payee: extractMerchant(from: text),
            cardHint: extractCardHint(from: text),
            date: extractDate(from: text),
            isIncome: isIncome,
            rawText: text
        )
    }

    // MARK: - Extraction helpers

    private static func normalizeCurrencyCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 3,
              code.unicodeScalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }),
              Locale.Currency.isoCurrencies.contains(where: { $0.identifier == code }) else {
            return nil
        }
        return code
    }

    /// Returns only currencies identified without relying on an ambiguous symbol.
    private static func extractCurrencyCode(from text: String) -> String? {
        let leadingPattern = #"(?<!\p{L})[\(\[]?([A-Za-z]{3})(?!\p{L})[\)\]]?\s*[.:=,;\-]?\s*(?=\d)"#
        if let code = currencyCode(in: text, matching: leadingPattern) {
            return code
        }

        let trailingPattern = #"\d[\d,]*(?:\.\d{1,2})?\s*[.:=,;\-]?\s*(?<!\p{L})([A-Za-z]{3})(?!\p{L})"#
        if let code = currencyCode(in: text, matching: trailingPattern) {
            return code
        }
        if text.contains("€") { return "EUR" }
        if text.contains("£") { return "GBP" }
        if text.contains("₹") { return "INR" }
        return nil
    }

    private static func currencyCode(in text: String, matching pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let candidate = String(text[range])
            if let code = normalizeCurrencyCode(candidate), isExplicitCurrencyCode(candidate) {
                return code
            }
        }
        return nil
    }

    // Lowercase ISO codes overlap ordinary prose ("all", "try", "pen").
    private static func isExplicitCurrencyCode(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value >= 65 && $0.value <= 90 }
    }

    /// Extract currency amount. Requires an explicit currency marker (leading or trailing)
    /// to avoid falsely capturing masked card or account numbers.
    private static func extractAmount(from text: String) -> Double? {
        // Pattern 1: Leading currency symbol or legacy marker: "$50.00", "Rs. 500"
        let leadingPattern = #"(?:[\$€£₹]|\brs\.?)\s*(\d[\d,]*(?:\.\d{1,2})?)"#
        if let regex = try? NSRegularExpression(pattern: leadingPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            return AmountParser.parse(String(text[range]))
        }

        // Pattern 2: Trailing currency symbol or legacy marker: "500.00 Rs", "25.50 €"
        let trailingPattern = #"(\d[\d,]*(?:\.\d{1,2})?)\s*(?:[\$€£₹]|\brs\b)"#
        if let regex = try? NSRegularExpression(pattern: trailingPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            return AmountParser.parse(String(text[range]))
        }

        let leadingCodePattern = #"(?<!\p{L})[\(\[]?([A-Za-z]{3})(?!\p{L})[\)\]]?\s*[.:=,;\-]?\s*(\d[\d,]*(?:\.\d{1,2})?)"#
        if let amount = amountAdjacentToCurrencyCode(
            in: text,
            pattern: leadingCodePattern,
            codeGroup: 1,
            amountGroup: 2
        ) {
            return amount
        }

        let trailingCodePattern = #"(\d[\d,]*(?:\.\d{1,2})?)\s*[.:=,;\-]?\s*(?<!\p{L})([A-Za-z]{3})(?!\p{L})"#
        if let amount = amountAdjacentToCurrencyCode(
            in: text,
            pattern: trailingCodePattern,
            codeGroup: 2,
            amountGroup: 1
        ) {
            return amount
        }

        // Pattern 3: Fall back to whole-text parse (only accepts single-number strings)
        return AmountParser.parse(text).flatMap { $0 > 0 ? $0 : nil }
    }

    private static func amountAdjacentToCurrencyCode(
        in text: String,
        pattern: String,
        codeGroup: Int,
        amountGroup: Int
    ) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let codeRange = Range(match.range(at: codeGroup), in: text),
                  let amountRange = Range(match.range(at: amountGroup), in: text) else { continue }
            let candidate = String(text[codeRange])
            guard normalizeCurrencyCode(candidate) != nil,
                  isExplicitCurrencyCode(candidate) else { continue }
            if let amount = AmountParser.parse(String(text[amountRange])) {
                return amount
            }
        }
        return nil
    }

    /// Extract the last 4 digits of a card / account number.
    private static func extractCardHint(from text: String) -> String? {
        // ponytail: simple pattern covering "card ending 1234", "XX9876",
        // "A/C ...4321", "a/c no 1234".
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

    /// Extract a merchant / payee name.
    private static func extractMerchant(from text: String) -> String? {
        // Keyword-based extraction for common bank SMS patterns with word boundaries.
        let pattern = #"\b(?:at|to|paid|merchant|vpa)\s+([A-Za-z0-9\s&'.]+?)(?:\s+(?:on|using|via|for|with|card|ref|\.|\,)|$)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            let candidate = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if isValidMerchantCandidate(candidate) {
                return candidate
            }
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
                let candidate = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if isValidMerchantCandidate(candidate) {
                    found = candidate
                    return false
                }
            }
            return true
        }
        return found
    }

    private static func isValidMerchantCandidate(_ candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        let lower = candidate.lowercased()
        // Reject candidates that are just numbers or card/account references
        let isCardReference = lower.starts(with: "card") || lower.starts(with: "a/c") || lower.starts(with: "acct")
        let isOnlyDigitsOrPunct = candidate.allSatisfy { $0.isNumber || $0.isWhitespace || $0.isPunctuation }
        return !isCardReference && !isOnlyDigitsOrPunct
    }
}
