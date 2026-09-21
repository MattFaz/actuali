import Testing
import Foundation
@testable import Actuali

struct LoanConfigTests {

    @Test func encodesAndDecodesJSON() throws {
        let config = LoanConfig(
            originalBalance: 2_200_000,
            annualRatePercent: 6.25,
            minimumPayment: 36500,
            escrowOrFees: 20000
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(LoanConfig.self, from: data)

        #expect(decoded == config)
    }

    @Test func decodesWithoutEscrow() throws {
        let json = """
        {
            "originalBalance": 2200000,
            "annualRatePercent": 6,
            "minimumPayment": 36500
        }
        """

        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(LoanConfig.self, from: data)

        #expect(decoded.originalBalance == 2_200_000)
        #expect(decoded.annualRatePercent == 6)
        #expect(decoded.minimumPayment == 36500)
        #expect(decoded.escrowOrFees == nil)
    }

    /// The config syncs, so a client on an older build will read JSON written by
    /// a newer one. Unknown keys have to be survivable or a loan configured on a
    /// newer device disappears here.
    @Test func ignoresKeysFromANewerClient() throws {
        let json = """
        {
            "originalBalance": 2200000,
            "annualRatePercent": 6,
            "minimumPayment": 36500,
            "targetPayment": 46500,
            "pairedCategoryId": "cat-1"
        }
        """

        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(LoanConfig.self, from: data)

        #expect(decoded.minimumPayment == 36500)
        #expect(decoded.escrowOrFees == nil)
    }

    @Test func rejectsJSONMissingARequiredField() throws {
        let json = """
        {
            "annualRatePercent": 6,
            "minimumPayment": 36500
        }
        """

        let data = try #require(json.data(using: .utf8))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LoanConfig.self, from: data)
        }
    }
}
