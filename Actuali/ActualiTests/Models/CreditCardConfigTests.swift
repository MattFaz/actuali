import Testing
import Foundation
@testable import Actuali

struct CreditCardConfigTests {

    @Test func encodesAndDecodesJSON() throws {
        let date = Date(timeIntervalSince1970: 1771848000) // Fixed timestamp
        let config = CreditCardConfig(
            statementDay: 18,
            dueOffsetDays: 25,
            limit: 500000,
            updatedAt: date
        )

        let json = try #require(config.toJSONString())
        let decoded = try #require(CreditCardConfig.from(jsonString: json))

        #expect(decoded.statementDay == 18)
        #expect(decoded.dueOffsetDays == 25)
        #expect(decoded.limit == 500000)
        #expect(abs(decoded.updatedAt.timeIntervalSince(date)) < 1.0)
    }

    @Test func decodesWithDefaultDueOffsetAndNoLimit() throws {
        let json = """
        {
            "statementDay": 15,
            "updatedAt": "2026-08-24T12:00:00Z"
        }
        """

        let decoded = try #require(CreditCardConfig.from(jsonString: json))
        #expect(decoded.statementDay == 15)
        #expect(decoded.dueOffsetDays == CreditCardCycle.defaultDueOffsetDays)
        #expect(decoded.limit == nil)
    }

    @Test func decodesMissingUpdatedAtGracefully() throws {
        let json = """
        {
            "statementDay": 20,
            "dueOffsetDays": 30,
            "limit": 100000
        }
        """

        let decoded = try #require(CreditCardConfig.from(jsonString: json))
        #expect(decoded.statementDay == 20)
        #expect(decoded.dueOffsetDays == 30)
        #expect(decoded.limit == 100000)
    }
}
