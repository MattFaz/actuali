import Testing
@testable import Actuali

struct MerchantNormalizerTests {

    @Test func stripsSquarePrefix() {
        #expect(MerchantNormalizer.normalize("SQ *BLUE BOTTLE") == "Blue Bottle")
        #expect(MerchantNormalizer.normalize("sq *blue bottle") == "Blue Bottle")
    }

    @Test func stripsToastPrefix() {
        #expect(MerchantNormalizer.normalize("TST* DOUGH") == "Dough")
        #expect(MerchantNormalizer.normalize("TST *DOUGH") == "Dough")
    }

    @Test func stripsShopifyPrefix() {
        #expect(MerchantNormalizer.normalize("SP COOL STORE") == "Cool Store")
    }

    @Test func stripsPaypalPrefix() {
        #expect(MerchantNormalizer.normalize("PAYPAL *MERCHANT") == "Merchant")
    }

    @Test func stripsTrailingStoreNumber() {
        #expect(MerchantNormalizer.normalize("BLUE BOTTLE #4") == "Blue Bottle")
        #expect(MerchantNormalizer.normalize("STARBUCKS #1234") == "Starbucks")
    }

    @Test func combinesPrefixAndStoreNumber() {
        #expect(MerchantNormalizer.normalize("SQ *BLUE BOTTLE #4") == "Blue Bottle")
    }

    @Test func trimsWhitespace() {
        #expect(MerchantNormalizer.normalize("  BLUE BOTTLE  ") == "Blue Bottle")
        #expect(MerchantNormalizer.normalize("SQ *  BLUE BOTTLE") == "Blue Bottle")
    }

    @Test func passesThroughCleanInput() {
        #expect(MerchantNormalizer.normalize("Blue Bottle") == "Blue Bottle")
    }

    @Test func handlesEmptyAndWhitespaceOnly() {
        #expect(MerchantNormalizer.normalize("") == "")
        #expect(MerchantNormalizer.normalize("   ") == "")
    }

    @Test func preservesInternalApostrophesAsLocalizedCapitalized() {
        #expect(MerchantNormalizer.normalize("MCDONALD'S #42") == "Mcdonald's")
    }
}
