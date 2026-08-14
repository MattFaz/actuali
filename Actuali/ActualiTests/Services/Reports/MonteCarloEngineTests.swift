import Foundation
import Testing
@testable import Actuali

/// Mirrors upstream monteCarloSimulation.test.ts. Deterministic (zero
/// volatility) scenarios are hand-computable; seeded scenarios pin values
/// computed with the upstream mulberry32/Box-Muller PRNG in node.
struct MonteCarloEngineTests {

    /// Upstream makePot: custom preset, mean 0.06, stdDev 0.1, balance 50M cents.
    private func pot(
        id: String = "pot-1",
        balance: Double = 50_000_000,
        mean: Double = 0.06,
        stdDev: Double = 0.1,
        accessAge: Double? = nil,
        taxRate: Double = 0,
        taxableFraction: Double = 1,
        feeFixed: Double = 0,
        feeRate: Double = 0,
        preset: MonteCarloAllocationPreset = .custom
    ) -> MonteCarloPot {
        var pot = MonteCarloPot(id: id)
        pot.startingBalance = balance
        pot.allocationPreset = preset
        pot.expectedReturnMean = mean
        pot.returnStdDev = stdDev
        pot.accessAge = accessAge
        pot.withdrawalTaxRate = taxRate
        pot.taxableFraction = taxableFraction
        pot.annualFeeFixed = feeFixed
        pot.annualFeeRate = feeRate
        return pot
    }

    /// Upstream makeParams: single phase, no inflation, no tax bands,
    /// horizon expressed via targetAge = 60 + horizonYears, 1000 sims.
    private func config(
        pots: [MonteCarloPot],
        annualWithdrawal: Double = 2_000_000,
        strategy: MonteCarloWithdrawalStrategy = .proportional,
        returnModel: MonteCarloReturnModel = .normal,
        rule: MonteCarloWithdrawalRule = MonteCarloWithdrawalRule(),
        minimumWithdrawal: Double = 0,
        phases: [MonteCarloSpendingPhase]? = nil,
        inflationMean: Double? = nil,
        inflationStdDev: Double = 0,
        taxModel: MonteCarloTaxModel = .flat,
        taxBands: [MonteCarloTaxBand] = [],
        horizonYears: Double = 30
    ) -> MonteCarloConfig {
        var config = MonteCarloConfig()
        config.pots = pots
        config.withdrawalStrategy = strategy
        config.returnModel = returnModel
        config.withdrawalRule = rule
        config.minimumWithdrawal = minimumWithdrawal
        config.spendingPhases = phases ?? [MonteCarloSpendingPhase(id: "phase-1", fromAge: nil, annualWithdrawal: annualWithdrawal)]
        config.inflationMean = inflationMean
        config.inflationStdDev = inflationStdDev
        config.taxModel = taxModel
        config.taxBands = taxBands
        config.currentAge = 60
        config.targetAge = 60 + horizonYears
        config.simulationCount = 1000
        return config
    }

    /// In deterministic runs every simulation is identical, so the first
    /// year whose median balance is zero is the depletion year.
    private func firstDepletedYear(_ data: MonteCarloData) -> Int? {
        data.percentileBands.first { $0.year >= 1 && $0.p50 == 0 }?.year
    }

    // MARK: PRNG parity with upstream

    @Test func mulberry32MatchesUpstreamSequence() {
        // First five uniforms of mulberry32(42) computed with the upstream
        // JS implementation in node
        var random = MonteCarloRandom(seed: 42)
        let expected = [
            0.60110375192016363, 0.44829055899754167, 0.85246579349040985,
            0.66973404143936932, 0.17481389874592423
        ]
        for value in expected {
            #expect(random.next() == value)
        }
    }

    @Test func boxMullerMatchesUpstreamSequence() {
        // First four normals of makeNormalSampler(mulberry32(42)) in node
        var random = MonteCarloRandom(seed: 42)
        let expected = [
            -1.2848381576290195, -0.94535280997472959,
            -0.61128028465146289, -0.56583258521268753
        ]
        for value in expected {
            #expect(random.nextNormal() == value)
        }
    }

    @Test func seededRunMatchesUpstreamReplica() {
        // Pinned from a node replica of the upstream engine's exact
        // random-call order for this config (seed 42, 1000 sims x 30 years,
        // single custom pot 50M, withdrawal 2M, mean 0.06, sd 0.1)
        let result = MonteCarloEngine.simulate(config: config(pots: [pot()]), seed: 42)
        #expect(result.successRate == 0.971)
        #expect(result.percentileBands[1].p50 == 51_097_236)
        #expect(result.percentileBands[1].p10 == 44_738_562)
        #expect(result.percentileBands[1].p90 == 57_505_924)
        #expect(result.percentileBands[30].p50 == 95_582_181)
    }

    // MARK: Horizon derivation

    @Test func horizonDerivedFromAgesAndClamped() {
        #expect(MonteCarloEngine.horizonYears(currentAge: 60, targetAge: 90) == 30)
        #expect(MonteCarloEngine.horizonYears(currentAge: 62.4, targetAge: 90) == 28)
        #expect(MonteCarloEngine.horizonYears(currentAge: 90, targetAge: 60) == 1)
        #expect(MonteCarloEngine.horizonYears(currentAge: 70, targetAge: 70) == 1)
        #expect(MonteCarloEngine.horizonYears(currentAge: 0, targetAge: 500) == 100)
    }

    // MARK: Deterministic closed-form scenarios

    @Test func closedFormDepletionWithZeroVolatility() {
        // Pot 1.2M cents, flat 0% return, withdraw 100k/yr: 12 full years,
        // hits exactly zero (and fails) in year 12
        let result = MonteCarloEngine.simulate(
            config: config(pots: [pot(balance: 1_200_000, mean: 0, stdDev: 0)], annualWithdrawal: 100_000),
            seed: 42
        )
        #expect(result.successRate == 0)
        #expect(firstDepletedYear(result) == 12)
        #expect(result.percentileBands[11].p50 == 100_000)
        #expect(result.percentileBands[0].p50 == 1_200_000)
    }

    @Test func survivesWhenReturnsOutpaceWithdrawals() {
        let result = MonteCarloEngine.simulate(
            config: config(pots: [pot(balance: 100_000, mean: 0.05, stdDev: 0)], annualWithdrawal: 3_000),
            seed: 42
        )
        #expect(result.successRate == 1)
        #expect(firstDepletedYear(result) == nil)
        #expect(result.percentileBands[30].p50 > 100_000)
    }

    @Test func alwaysSucceedsWithNoWithdrawals() {
        let result = MonteCarloEngine.simulate(
            config: config(pots: [pot(stdDev: 0.2)], annualWithdrawal: 0),
            seed: 42
        )
        #expect(result.successRate == 1)
    }

    @Test func depletesInYearOneWhenWithdrawalExceedsPot() {
        let result = MonteCarloEngine.simulate(
            config: config(pots: [pot(balance: 10_000)], annualWithdrawal: 20_000),
            seed: 42
        )
        #expect(result.successRate == 0)
        #expect(firstDepletedYear(result) == 1)
    }

    @Test func inflationGrowsWithdrawals() {
        // pot 200, withdrawal 50, no growth, 100% inflation:
        // y1: 200-50=150 (w -> 100); y2: 150-100=50 (w -> 200); y3: depleted
        let inflated = MonteCarloEngine.simulate(
            config: config(
                pots: [pot(balance: 200, mean: 0, stdDev: 0)],
                annualWithdrawal: 50, inflationMean: 1, horizonYears: 10
            ),
            seed: 42
        )
        #expect(firstDepletedYear(inflated) == 3)

        // Flat withdrawals last one year longer: y4 hits exactly 0
        let flat = MonteCarloEngine.simulate(
            config: config(
                pots: [pot(balance: 200, mean: 0, stdDev: 0)],
                annualWithdrawal: 50, inflationMean: nil, horizonYears: 10
            ),
            seed: 42
        )
        #expect(firstDepletedYear(flat) == 4)
    }

    @Test func spendingPhasesSwitchAtStartingAge() {
        // Ages 60-64 spend 10k (years 1-5), from 65 spend 20k
        let result = MonteCarloEngine.simulate(
            config: config(
                pots: [pot(balance: 1_000_000, mean: 0, stdDev: 0)],
                phases: [
                    MonteCarloSpendingPhase(id: "phase-1", fromAge: nil, annualWithdrawal: 10_000),
                    MonteCarloSpendingPhase(id: "phase-2", fromAge: 65, annualWithdrawal: 20_000)
                ],
                horizonYears: 13
            ),
            seed: 42
        )
        #expect(result.percentileBands[5].p50 == 950_000)
        #expect(result.percentileBands[6].p50 == 930_000)
        #expect(result.percentileBands[13].p50 == 1_000_000 - 5 * 10_000 - 8 * 20_000)
    }

    // MARK: Withdrawal rules

    @Test func boundariesCutWithdrawalsAndExtendSurvival() {
        // 10% withdrawal rate on a flat pot depletes in exactly year 10
        let base = config(
            pots: [pot(balance: 100_000, mean: 0, stdDev: 0)],
            annualWithdrawal: 10_000
        )
        let withoutRule = MonteCarloEngine.simulate(config: base, seed: 42)
        #expect(firstDepletedYear(withoutRule) == 10)

        var rule = MonteCarloWithdrawalRule()
        rule.type = .boundaries
        var withRuleConfig = base
        withRuleConfig.withdrawalRule = rule
        let withRule = MonteCarloEngine.simulate(config: withRuleConfig, seed: 42)
        #expect((firstDepletedYear(withRule) ?? Int.max) > 10)
    }

    @Test func floorCeilingScalesWithdrawalsWithinLimits() {
        var rule = MonteCarloWithdrawalRule()
        rule.type = .floorCeiling
        rule.floorPct = 0.5
        rule.ceilingPct = 0.5
        let result = MonteCarloEngine.simulate(
            config: config(
                pots: [pot(balance: 100_000, mean: 0, stdDev: 0)],
                annualWithdrawal: 10_000, rule: rule
            ),
            seed: 42
        )
        #expect((firstDepletedYear(result) ?? Int.max) > 14)
    }

    @Test func guardrailsRaiseWithdrawalsWhenPotRacesAhead() {
        // 4% initial rate with steady 20% growth triggers prosperity raises;
        // the extra income leaves a lower ending balance than no rule
        let base = config(
            pots: [pot(balance: 100_000, mean: 0.2, stdDev: 0)],
            annualWithdrawal: 4_000, horizonYears: 20
        )
        let withoutRule = MonteCarloEngine.simulate(config: base, seed: 42)
        var rule = MonteCarloWithdrawalRule()
        rule.type = .guardrails
        var withRuleConfig = base
        withRuleConfig.withdrawalRule = rule
        let withRule = MonteCarloEngine.simulate(config: withRuleConfig, seed: 42)

        #expect(withRule.successRate == 1)
        #expect(withRule.percentileBands[20].p50 < withoutRule.percentileBands[20].p50)
    }

    @Test func ratchetingIncreasesWithdrawalsAfterConsecutiveYears() {
        let base = config(
            pots: [pot(balance: 100_000, mean: 0.3, stdDev: 0)],
            annualWithdrawal: 1_000, horizonYears: 20
        )
        let withoutRule = MonteCarloEngine.simulate(config: base, seed: 42)
        var rule = MonteCarloWithdrawalRule()
        rule.type = .ratcheting
        rule.balanceThresholdMultiple = 1.5
        rule.consecutiveYears = 3
        rule.ratchetIncreasePct = 0.5
        var withRuleConfig = base
        withRuleConfig.withdrawalRule = rule
        let withRule = MonteCarloEngine.simulate(config: withRuleConfig, seed: 42)

        #expect(withRule.percentileBands[20].p50 < withoutRule.percentileBands[20].p50)
    }

    @Test func minimumWithdrawalFloorNeutralizesRuleCuts() {
        let base = config(
            pots: [pot(balance: 100_000, mean: 0, stdDev: 0)],
            annualWithdrawal: 10_000
        )
        let withoutRule = MonteCarloEngine.simulate(config: base, seed: 42)

        var rule = MonteCarloWithdrawalRule()
        rule.type = .boundaries
        var flooredConfig = base
        flooredConfig.withdrawalRule = rule
        flooredConfig.minimumWithdrawal = 10_000
        let cutsFloored = MonteCarloEngine.simulate(config: flooredConfig, seed: 42)

        #expect(cutsFloored.percentileBands == withoutRule.percentileBands)
    }

    @Test func minimumWithdrawalIgnoredWithoutActiveRule() {
        // Upstream: with no rule the planned spending is taken as-is
        let base = config(
            pots: [pot(balance: 100_000, mean: 0, stdDev: 0)],
            annualWithdrawal: 5_000
        )
        var flooredConfig = base
        flooredConfig.minimumWithdrawal = 50_000
        let result = MonteCarloEngine.simulate(config: flooredConfig, seed: 42)
        let baseline = MonteCarloEngine.simulate(config: base, seed: 42)
        #expect(result.percentileBands == baseline.percentileBands)
    }

    // MARK: Access ages

    @Test func failsWhenAccessiblePotsRunDryBeforeLockedPotUnlocks() {
        // Accessible 100 funds 30/year: y1 70, y2 40, y3 10, year 4 fails;
        // the pot locked until age 120 doesn't save the plan
        let result = MonteCarloEngine.simulate(
            config: config(
                pots: [
                    pot(id: "isa", balance: 100, mean: 0, stdDev: 0),
                    pot(id: "pension", balance: 1_000, mean: 0, stdDev: 0, accessAge: 120)
                ],
                annualWithdrawal: 30, horizonYears: 20
            ),
            seed: 42
        )
        #expect(result.successRate == 0)
        #expect(firstDepletedYear(result) == 4)
    }

    @Test func survivesWhenLockedPotUnlocksInTime() {
        // Same setup, but the pension unlocks at 63 - exactly year 4
        let result = MonteCarloEngine.simulate(
            config: config(
                pots: [
                    pot(id: "isa", balance: 100, mean: 0, stdDev: 0),
                    pot(id: "pension", balance: 1_000, mean: 0, stdDev: 0, accessAge: 63)
                ],
                annualWithdrawal: 30, horizonYears: 20
            ),
            seed: 42
        )
        #expect(result.successRate == 1)
    }

    @Test func accessAgeAtOrBelowCurrentAgeIsImmediate() {
        let immediate = MonteCarloEngine.simulate(config: config(pots: [pot(accessAge: nil)]), seed: 42)
        let alreadyReached = MonteCarloEngine.simulate(config: config(pots: [pot(accessAge: 40)]), seed: 42)
        #expect(immediate == alreadyReached)
    }

    @Test func sequentialOrderSkipsLockedPotsUntilTheyUnlock() {
        // First-listed pot locked past the horizon, so sequential drains the
        // second pot: 100 at 10/year fails in year 10
        let result = MonteCarloEngine.simulate(
            config: config(
                pots: [
                    pot(id: "locked", balance: 1_000, mean: 0, stdDev: 0, accessAge: 200),
                    pot(id: "open", balance: 100, mean: 0, stdDev: 0)
                ],
                annualWithdrawal: 10, strategy: .sequential, horizonYears: 20
            ),
            seed: 42
        )
        #expect(result.successRate == 0)
        #expect(firstDepletedYear(result) == 10)
    }

    // MARK: Tax

    @Test func flatTaxGrossesUpWithdrawals() {
        // 20% tax pot: delivering 8,000 net costs 10,000 gross each year, so
        // 95,000 funds nine full years and fails in year ten
        let result = MonteCarloEngine.simulate(
            config: config(
                pots: [pot(balance: 95_000, mean: 0, stdDev: 0, taxRate: 0.2)],
                annualWithdrawal: 8_000, horizonYears: 12
            ),
            seed: 42
        )
        #expect(result.successRate == 0)
        #expect(firstDepletedYear(result) == 10)
        #expect(result.percentileBands[9].p50 == 5_000)
    }

    @Test func taxBandsGrossUpProgressively() {
        // Bands: first 10,000 tax-free, 20% above. Delivering 18,000 net
        // needs 20,000 gross each year
        let result = MonteCarloEngine.simulate(
            config: config(
                pots: [pot(balance: 200_000, mean: 0, stdDev: 0)],
                annualWithdrawal: 18_000,
                taxModel: .bands,
                taxBands: [
                    MonteCarloTaxBand(id: "a", from: 0, rate: 0),
                    MonteCarloTaxBand(id: "b", from: 10_000, rate: 0.2)
                ],
                horizonYears: 3
            ),
            seed: 42
        )
        #expect(result.percentileBands[1].p50 == 180_000)
        #expect(result.percentileBands[2].p50 == 160_000)
        #expect(result.percentileBands[3].p50 == 140_000)
    }

    @Test func taxBandsPoolTaxableIncomeAcrossPots() {
        // Proportional split takes half the gross from each pot; only the
        // pension half is 75% taxable, so taxable income is 0.375x gross.
        // Solving 0.925g = 38,000 gives g = 41,081.08 for 40,000 net
        let result = MonteCarloEngine.simulate(
            config: config(
                pots: [
                    pot(id: "isa", balance: 100_000, mean: 0, stdDev: 0, taxableFraction: 0),
                    pot(id: "pension", balance: 100_000, mean: 0, stdDev: 0, taxableFraction: 0.75)
                ],
                annualWithdrawal: 40_000,
                taxModel: .bands,
                taxBands: [
                    MonteCarloTaxBand(id: "a", from: 0, rate: 0),
                    MonteCarloTaxBand(id: "b", from: 10_000, rate: 0.2)
                ],
                horizonYears: 1
            ),
            seed: 42
        )
        // 200,000 - 41,081.081... = 158,918.92 rounds to 158,919
        #expect(result.percentileBands[1].p50 == 158_919)
    }

    @Test func singleTaxBandBehavesLikeFlatRate() {
        let flat = MonteCarloEngine.simulate(
            config: config(pots: [pot(taxRate: 0.25)]),
            seed: 42
        )
        let bands = MonteCarloEngine.simulate(
            config: config(
                pots: [pot(taxableFraction: 1)],
                taxModel: .bands,
                taxBands: [MonteCarloTaxBand(id: "a", from: 0, rate: 0.25)]
            ),
            seed: 42
        )
        #expect(bands.successRate == flat.successRate)
        #expect(abs(bands.percentileBands[30].p50 - flat.percentileBands[30].p50) <= 1)
    }

    @Test func zeroRateTaxMatchesUntaxedEngineExactly() {
        let untaxed = MonteCarloEngine.simulate(config: config(pots: [pot()]), seed: 42)
        let zeroBands = MonteCarloEngine.simulate(
            config: config(
                pots: [pot()],
                taxModel: .bands,
                taxBands: [MonteCarloTaxBand(id: "a", from: 0, rate: 0)]
            ),
            seed: 42
        )
        #expect(zeroBands.percentileBands == untaxed.percentileBands)
        #expect(zeroBands.successRate == untaxed.successRate)
    }

    // MARK: Fees

    @Test func fixedFeeDeductedAtYearEnd() {
        let result = MonteCarloEngine.simulate(
            config: config(
                pots: [pot(balance: 100_000, mean: 0, stdDev: 0, feeFixed: 1_000)],
                annualWithdrawal: 0, horizonYears: 5
            ),
            seed: 42
        )
        #expect(result.percentileBands[1].p50 == 99_000)
        #expect(result.percentileBands[2].p50 == 98_000)
    }

    @Test func percentageFeeDeductedFromEndOfYearBalance() {
        let result = MonteCarloEngine.simulate(
            config: config(
                pots: [pot(balance: 100_000, mean: 0, stdDev: 0, feeRate: 0.01)],
                annualWithdrawal: 0, horizonYears: 5
            ),
            seed: 42
        )
        #expect(result.percentileBands[1].p50 == 99_000)
        #expect(result.percentileBands[2].p50 == 98_010)
    }

    @Test func feesAloneCanDepleteAPlan() {
        let result = MonteCarloEngine.simulate(
            config: config(
                pots: [pot(balance: 10_000, mean: 0, stdDev: 0, feeFixed: 5_000)],
                annualWithdrawal: 0, horizonYears: 10
            ),
            seed: 42
        )
        #expect(result.successRate == 0)
        #expect(firstDepletedYear(result) == 2)
    }

    // MARK: Historical models

    @Test func bootstrapWithOneYearHistoryIsDeterministic() {
        // A single history year means every bootstrap draw returns it; an
        // equity-60 pot earns the blended 0.6*0.1 + 0.4*0.1 = 10% every year
        let result = MonteCarloEngine.simulate(
            config: config(
                pots: [pot(balance: 100_000, mean: 0, stdDev: 0, preset: .equity60)],
                annualWithdrawal: 10_000,
                returnModel: .historicalBootstrap,
                horizonYears: 5
            ),
            seed: 42,
            historicalReturns: [MonteCarloHistoricalReturn(year: 2000, stocks: 0.1, bonds: 0.1, cash: 0.1)]
        )
        // (100,000 - 10,000) * 1.1 = 99,000; (99,000 - 10,000) * 1.1 = 97,900
        #expect(result.percentileBands[1].p50 == 99_000)
        #expect(result.percentileBands[2].p50 == 97_900)
    }

    @Test func sequenceModeRunsOneScenarioPerStartYear() {
        let history = [
            MonteCarloHistoricalReturn(year: 2000, stocks: 0.1, bonds: 0.1, cash: 0.1),
            MonteCarloHistoricalReturn(year: 2001, stocks: -0.2, bonds: -0.2, cash: -0.2),
            MonteCarloHistoricalReturn(year: 2002, stocks: 0.05, bonds: 0.05, cash: 0.05)
        ]
        let result = MonteCarloEngine.simulate(
            config: config(
                pots: [pot(preset: .equity60)],
                returnModel: .historicalSequence,
                horizonYears: 10
            ),
            seed: 42,
            historicalReturns: history
        )
        #expect(result.simulationCount == history.count)
    }

    // MARK: Determinism and statistics

    @Test func deterministicForAGivenSeed() {
        let firstRun = MonteCarloEngine.simulate(config: config(pots: [pot()]), seed: 7)
        let secondRun = MonteCarloEngine.simulate(config: config(pots: [pot()]), seed: 7)
        #expect(firstRun == secondRun)

        let differentSeed = MonteCarloEngine.simulate(config: config(pots: [pot()]), seed: 8)
        #expect(differentSeed.percentileBands != firstRun.percentileBands)
    }

    @Test func producesOrderedPercentileBands() {
        let result = MonteCarloEngine.simulate(config: config(pots: [pot(stdDev: 0.15)]), seed: 42)
        for band in result.percentileBands {
            #expect(band.p5 <= band.p10)
            #expect(band.p10 <= band.p25)
            #expect(band.p25 <= band.p30)
            #expect(band.p30 <= band.p50)
            #expect(band.p50 <= band.p70)
            #expect(band.p70 <= band.p75)
            #expect(band.p75 <= band.p90)
        }
        #expect(result.percentileBands.count == result.horizonYears + 1)
        #expect(result.percentileBands[0].p10 == 50_000_000)
        #expect(result.percentileBands[0].p90 == 50_000_000)
    }

    // MARK: Meta decoding and account resolution

    @Test func metaDistinguishesNullInflationFromAbsent() throws {
        let explicitNull = try JSONDecoder().decode(
            MonteCarloMeta.self,
            from: Data(#"{"inflationMean": null}"#.utf8)
        )
        #expect(MonteCarloEngine.config(from: explicitNull).inflationMean == nil)

        let absent = try JSONDecoder().decode(MonteCarloMeta.self, from: Data("{}".utf8))
        #expect(MonteCarloEngine.config(from: absent).inflationMean == 0.025)
    }

    @Test func configFromMetaAppliesUpstreamDefaults() throws {
        let meta = try JSONDecoder().decode(
            MonteCarloMeta.self,
            from: Data(#"{"pots":[{"id":"p1","startingBalance":123}],"withdrawalStrategy":"best-performer","returnModel":"historical-bootstrap","currentAge":55,"targetAge":85}"#.utf8)
        )
        let config = MonteCarloEngine.config(from: meta)
        #expect(config.pots.count == 1)
        #expect(config.pots[0].startingBalance == 123)
        #expect(config.pots[0].allocationPreset == .equity60)
        #expect(config.pots[0].taxableFraction == 1)
        #expect(config.withdrawalStrategy == .bestPerformer)
        #expect(config.returnModel == .historicalBootstrap)
        #expect(config.withdrawalRule.type == .none)
        #expect(config.currentAge == 55)
        #expect(config.targetAge == 85)
        #expect(config.simulationCount == 5000)
    }

    @Test func computeResolvesAccountLinkedPotBalances() throws {
        // A pot linked to an account takes the account's live balance
        // (clamped at zero); unlinked pots keep their stored balance
        let meta = MonteCarloMeta(
            pots: [
                MonteCarloPotMeta(
                    id: "p1", name: nil, startingBalance: 1_200_000, allocationPreset: "custom",
                    expectedReturnMean: 0, returnStdDev: 0, accessAge: nil, accountId: "acct-1",
                    withdrawalTaxRate: nil, taxableFraction: nil, annualFeeFixed: nil,
                    feeAdjustsWithInflation: nil, annualFeeRate: nil
                )
            ],
            spendingPhases: [MonteCarloSpendingPhaseMeta(id: "s1", name: nil, fromAge: nil, annualWithdrawal: 100_000)],
            inflationMean: .some(nil),
            currentAge: 60,
            targetAge: 90
        )
        // 600k cents from the account instead of the stored 1.2M: depletes
        // in year 6 instead of year 12
        let result = MonteCarloEngine.compute(meta: meta, accountBalances: ["acct-1": 600_000])
        #expect(result.successRate == 0)
        #expect(firstDepletedYear(result) == 6)

        let negative = MonteCarloEngine.compute(meta: meta, accountBalances: ["acct-1": -500])
        #expect(negative.percentileBands[0].p50 == 0)

        let unresolved = MonteCarloEngine.compute(meta: meta)
        #expect(firstDepletedYear(unresolved) == 12)
    }
}
