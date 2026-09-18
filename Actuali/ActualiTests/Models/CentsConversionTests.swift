//
//  CentsConversionTests.swift
//  ActualiTests
//
//  Created by Matt Farrell on 29/4/2026.
//

@testable import Actuali
import Testing

struct CentsConversionTests {
    @Test func roundsValuesThatTruncationWouldDrop() throws {
        // Double("8.20")! * 100 == 819.9999..., truncation gave 819
        #expect(try Transaction.cents(fromDollars: #require(Double("8.20"))) == 820)
        #expect(try Transaction.cents(fromDollars: #require(Double("0.07"))) == 7)
        #expect(try Transaction.cents(fromDollars: #require(Double("1.15"))) == 115)
        #expect(try Transaction.cents(fromDollars: #require(Double("4.10"))) == 410)
    }

    @Test func exactValues() {
        #expect(Transaction.cents(fromDollars: 0) == 0)
        #expect(Transaction.cents(fromDollars: 10.50) == 1050)
        #expect(Transaction.cents(fromDollars: 100) == 10000)
    }

    @Test func negativeAmountsRoundAwayFromZero() throws {
        #expect(try Transaction.cents(fromDollars: #require(Double("-8.20"))) == -820)
        #expect(Transaction.cents(fromDollars: -1.15) == -115)
        #expect(Transaction.cents(fromDollars: -0.07) == -7)
    }

    @Test func largeButValidAmounts() {
        // Max amount the keypad allows: 10 integer digits + 2 fraction digits
        #expect(Transaction.cents(fromDollars: 9_999_999_999.99) == 999_999_999_999)
    }

    @Test func rejectsNonFiniteAndOutOfRange() {
        #expect(Transaction.cents(fromDollars: Double.nan) == nil)
        #expect(Transaction.cents(fromDollars: Double.infinity) == nil)
        #expect(Transaction.cents(fromDollars: -Double.infinity) == nil)
        #expect(Transaction.cents(fromDollars: 1e308) == nil)
        #expect(Transaction.cents(fromDollars: -1e308) == nil)
        #expect(Transaction.cents(fromDollars: Double(Int.max)) == nil)
    }
}
