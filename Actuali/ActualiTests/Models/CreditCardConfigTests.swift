import Testing
import Foundation
@testable import Actuali

struct CreditCardConfigTests {

    @Test func encodesAndDecodesJSON() throws {
        let config = CreditCardConfig(
            statementDay: 18,
            dueOffsetDays: 25,
            limit: 500000
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CreditCardConfig.self, from: data)

        #expect(decoded.statementDay == 18)
        #expect(decoded.dueOffsetDays == 25)
        #expect(decoded.limit == 500000)
    }

    @Test func decodesWithDefaultDueOffsetAndNoLimit() throws {
        let json = """
        {
            "statementDay": 15
        }
        """

        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(CreditCardConfig.self, from: data)
        #expect(decoded.statementDay == 15)
        #expect(decoded.dueOffsetDays == CreditCardCycle.defaultDueOffsetDays)
        #expect(decoded.limit == nil)
    }
}
