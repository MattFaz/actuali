import Foundation

// MARK: - Widget meta (upstream loot-core dashboard.ts, MonteCarloWidget)

struct MonteCarloPotMeta: Codable, Equatable {
    let id: String?
    let name: String?
    /// Starting balance in minor units (cents).
    let startingBalance: Double?
    /// One of "equity-100" | "equity-80" | "equity-60" | "equity-40" | "cash" | "custom".
    let allocationPreset: String?
    let expectedReturnMean: Double?
    let returnStdDev: Double?
    /// Age from which the pot can fund withdrawals; nil = immediately.
    let accessAge: Double?
    /// Account whose live balance supplies the starting balance; nil = manual.
    let accountId: String?
    let withdrawalTaxRate: Double?
    let taxableFraction: Double?
    let annualFeeFixed: Double?
    let feeAdjustsWithInflation: Bool?
    let annualFeeRate: Double?
}

struct MonteCarloWithdrawalRuleMeta: Codable, Equatable {
    /// One of "none" | "guardrails" | "ratcheting" | "floor-ceiling" | "boundaries".
    let type: String?
    let prosperityTriggerPct: Double?
    let prosperityIncreasePct: Double?
    let preservationTriggerPct: Double?
    let preservationCutPct: Double?
    let balanceThresholdMultiple: Double?
    let consecutiveYears: Double?
    let ratchetIncreasePct: Double?
    let floorPct: Double?
    let ceilingPct: Double?
    let upperRateThreshold: Double?
    let upperCutPct: Double?
    let lowerRateThreshold: Double?
    let lowerIncreasePct: Double?
}

struct MonteCarloSpendingPhaseMeta: Codable, Equatable {
    let id: String?
    let name: String?
    /// Age the phase begins (inclusive); nil = starts immediately.
    let fromAge: Double?
    /// Yearly spending in minor units, in today's money.
    let annualWithdrawal: Double?
}

struct MonteCarloTaxBandMeta: Codable, Equatable {
    let id: String?
    /// Annual taxable income threshold in minor units, today's money.
    let from: Double?
    /// Decimal fraction (0.2 = 20%).
    let rate: Double?
}

struct MonteCarloMeta: Codable, Equatable {
    let name: String?
    let pots: [MonteCarloPotMeta]?
    let withdrawalStrategy: String?
    let returnModel: String?
    let withdrawalRule: MonteCarloWithdrawalRuleMeta?
    let minimumWithdrawal: Double?
    let spendingPhases: [MonteCarloSpendingPhaseMeta]?
    /// Upstream distinguishes absent (use the default) from an explicit JSON
    /// null (flat withdrawals): outer nil = absent, `.some(nil)` = null.
    let inflationMean: Double??
    let inflationStdDev: Double?
    let taxModel: String?
    let taxBands: [MonteCarloTaxBandMeta]?
    let currentAge: Double?
    let targetAge: Double?
    let simulationCount: Double?

    private enum CodingKeys: String, CodingKey {
        case name, pots, withdrawalStrategy, returnModel, withdrawalRule
        case minimumWithdrawal, spendingPhases, inflationMean, inflationStdDev
        case taxModel, taxBands, currentAge, targetAge, simulationCount
    }

    init(
        name: String? = nil,
        pots: [MonteCarloPotMeta]? = nil,
        withdrawalStrategy: String? = nil,
        returnModel: String? = nil,
        withdrawalRule: MonteCarloWithdrawalRuleMeta? = nil,
        minimumWithdrawal: Double? = nil,
        spendingPhases: [MonteCarloSpendingPhaseMeta]? = nil,
        inflationMean: Double?? = nil,
        inflationStdDev: Double? = nil,
        taxModel: String? = nil,
        taxBands: [MonteCarloTaxBandMeta]? = nil,
        currentAge: Double? = nil,
        targetAge: Double? = nil,
        simulationCount: Double? = nil
    ) {
        self.name = name
        self.pots = pots
        self.withdrawalStrategy = withdrawalStrategy
        self.returnModel = returnModel
        self.withdrawalRule = withdrawalRule
        self.minimumWithdrawal = minimumWithdrawal
        self.spendingPhases = spendingPhases
        self.inflationMean = inflationMean
        self.inflationStdDev = inflationStdDev
        self.taxModel = taxModel
        self.taxBands = taxBands
        self.currentAge = currentAge
        self.targetAge = targetAge
        self.simulationCount = simulationCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        pots = try container.decodeIfPresent([MonteCarloPotMeta].self, forKey: .pots)
        withdrawalStrategy = try container.decodeIfPresent(String.self, forKey: .withdrawalStrategy)
        returnModel = try container.decodeIfPresent(String.self, forKey: .returnModel)
        withdrawalRule = try container.decodeIfPresent(MonteCarloWithdrawalRuleMeta.self, forKey: .withdrawalRule)
        minimumWithdrawal = try container.decodeIfPresent(Double.self, forKey: .minimumWithdrawal)
        spendingPhases = try container.decodeIfPresent([MonteCarloSpendingPhaseMeta].self, forKey: .spendingPhases)
        if container.contains(.inflationMean) {
            inflationMean = .some(try container.decodeIfPresent(Double.self, forKey: .inflationMean))
        } else {
            inflationMean = nil
        }
        inflationStdDev = try container.decodeIfPresent(Double.self, forKey: .inflationStdDev)
        taxModel = try container.decodeIfPresent(String.self, forKey: .taxModel)
        taxBands = try container.decodeIfPresent([MonteCarloTaxBandMeta].self, forKey: .taxBands)
        currentAge = try container.decodeIfPresent(Double.self, forKey: .currentAge)
        targetAge = try container.decodeIfPresent(Double.self, forKey: .targetAge)
        simulationCount = try container.decodeIfPresent(Double.self, forKey: .simulationCount)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(pots, forKey: .pots)
        try container.encodeIfPresent(withdrawalStrategy, forKey: .withdrawalStrategy)
        try container.encodeIfPresent(returnModel, forKey: .returnModel)
        try container.encodeIfPresent(withdrawalRule, forKey: .withdrawalRule)
        try container.encodeIfPresent(minimumWithdrawal, forKey: .minimumWithdrawal)
        try container.encodeIfPresent(spendingPhases, forKey: .spendingPhases)
        if let wrapped = inflationMean {
            if let value = wrapped {
                try container.encode(value, forKey: .inflationMean)
            } else {
                try container.encodeNil(forKey: .inflationMean)
            }
        }
        try container.encodeIfPresent(inflationStdDev, forKey: .inflationStdDev)
        try container.encodeIfPresent(taxModel, forKey: .taxModel)
        try container.encodeIfPresent(taxBands, forKey: .taxBands)
        try container.encodeIfPresent(currentAge, forKey: .currentAge)
        try container.encodeIfPresent(targetAge, forKey: .targetAge)
        try container.encodeIfPresent(simulationCount, forKey: .simulationCount)
    }
}

// MARK: - Resolved configuration (upstream monteCarloSimulation.ts)

enum MonteCarloWithdrawalStrategy: String {
    case proportional
    case sequential
    case bestPerformer = "best-performer"
    case targetMix = "target-mix"
}

enum MonteCarloReturnModel: String {
    case normal
    case historicalBootstrap = "historical-bootstrap"
    case historicalSequence = "historical-sequence"
}

enum MonteCarloTaxModel: String {
    case flat
    case bands
}

enum MonteCarloWithdrawalRuleType: String {
    case none
    case guardrails
    case ratcheting
    case floorCeiling = "floor-ceiling"
    case boundaries
}

enum MonteCarloAllocationPreset: String {
    case equity100 = "equity-100"
    case equity80 = "equity-80"
    case equity60 = "equity-60"
    case equity40 = "equity-40"
    case cash
    case custom

    /// Asset mix behind each preset, used by the historical return models
    /// (upstream PRESET_ASSET_WEIGHTS).
    var assetWeights: (stocks: Double, bonds: Double, cash: Double)? {
        switch self {
        case .equity100: return (1, 0, 0)
        case .equity80: return (0.8, 0.2, 0)
        case .equity60: return (0.6, 0.4, 0)
        case .equity40: return (0.4, 0.6, 0)
        case .cash: return (0, 0, 1)
        case .custom: return nil
        }
    }
}

/// One invested pot; defaults mirror upstream createMonteCarloPot.
struct MonteCarloPot: Equatable {
    var id: String
    var name: String = ""
    var startingBalance: Double = 50_000_000
    var allocationPreset: MonteCarloAllocationPreset = .equity60
    var expectedReturnMean: Double = 0.06
    var returnStdDev: Double = 0.1
    var accessAge: Double?
    var accountId: String?
    var withdrawalTaxRate: Double = 0
    var taxableFraction: Double = 1
    var annualFeeFixed: Double = 0
    var feeAdjustsWithInflation: Bool = false
    var annualFeeRate: Double = 0
}

/// Fully-populated rule settings; defaults mirror upstream WITHDRAWAL_RULE_DEFAULTS.
struct MonteCarloWithdrawalRule: Equatable {
    var type: MonteCarloWithdrawalRuleType = .none
    // Guardrails (Guyton-Klinger)
    var prosperityTriggerPct: Double = 0.2
    var prosperityIncreasePct: Double = 0.1
    var preservationTriggerPct: Double = 0.2
    var preservationCutPct: Double = 0.1
    // Ratcheting (Kitces)
    var balanceThresholdMultiple: Double = 1.5
    var consecutiveYears: Double = 3
    var ratchetIncreasePct: Double = 0.05
    // Floor & ceiling (Bengen)
    var floorPct: Double = 0.15
    var ceilingPct: Double = 0.2
    // Boundaries
    var upperRateThreshold: Double = 0.06
    var upperCutPct: Double = 0.1
    var lowerRateThreshold: Double = 0.04
    var lowerIncreasePct: Double = 0.05
}

struct MonteCarloSpendingPhase: Equatable {
    var id: String
    var name: String = ""
    var fromAge: Double?
    var annualWithdrawal: Double = 2_000_000
}

struct MonteCarloTaxBand: Equatable {
    var id: String
    var from: Double = 0
    var rate: Double = 0
}

/// Defaults mirror upstream MONTE_CARLO_DEFAULTS.
struct MonteCarloConfig: Equatable {
    var pots: [MonteCarloPot] = [MonteCarloPot(id: "pot-1")]
    var withdrawalStrategy: MonteCarloWithdrawalStrategy = .proportional
    var returnModel: MonteCarloReturnModel = .normal
    var withdrawalRule = MonteCarloWithdrawalRule()
    var minimumWithdrawal: Double = 0
    var spendingPhases: [MonteCarloSpendingPhase] = [MonteCarloSpendingPhase(id: "phase-1")]
    /// nil = flat withdrawals (upstream's explicit null).
    var inflationMean: Double? = 0.025
    var inflationStdDev: Double = 0.02
    var taxModel: MonteCarloTaxModel = .flat
    var taxBands: [MonteCarloTaxBand] = [MonteCarloTaxBand(id: "band-1")]
    var currentAge: Double = 60
    var targetAge: Double = 90
    var simulationCount: Double = 5000
}

// MARK: - Historical returns (upstream monteCarloHistoricalReturns.ts)

/// Historical annual nominal US returns (Damodaran, NYU Stern, 1928-2025):
/// stocks = S&P 500 total return, bonds = 10y Treasury, cash = 3m T-bill.
struct MonteCarloHistoricalReturn: Equatable {
    let year: Int
    let stocks: Double
    let bonds: Double
    let cash: Double

    static let all: [MonteCarloHistoricalReturn] = [
        MonteCarloHistoricalReturn(year: 1928, stocks: 0.4381, bonds: 0.0084, cash: 0.0308),
        MonteCarloHistoricalReturn(year: 1929, stocks: -0.083, bonds: 0.042, cash: 0.0316),
        MonteCarloHistoricalReturn(year: 1930, stocks: -0.2512, bonds: 0.0454, cash: 0.0455),
        MonteCarloHistoricalReturn(year: 1931, stocks: -0.4384, bonds: -0.0256, cash: 0.0231),
        MonteCarloHistoricalReturn(year: 1932, stocks: -0.0864, bonds: 0.0879, cash: 0.0107),
        MonteCarloHistoricalReturn(year: 1933, stocks: 0.4998, bonds: 0.0186, cash: 0.0096),
        MonteCarloHistoricalReturn(year: 1934, stocks: -0.0119, bonds: 0.0796, cash: 0.0028),
        MonteCarloHistoricalReturn(year: 1935, stocks: 0.4674, bonds: 0.0447, cash: 0.0017),
        MonteCarloHistoricalReturn(year: 1936, stocks: 0.3194, bonds: 0.0502, cash: 0.0017),
        MonteCarloHistoricalReturn(year: 1937, stocks: -0.3534, bonds: 0.0138, cash: 0.0028),
        MonteCarloHistoricalReturn(year: 1938, stocks: 0.2928, bonds: 0.0421, cash: 0.0007),
        MonteCarloHistoricalReturn(year: 1939, stocks: -0.011, bonds: 0.0441, cash: 0.0005),
        MonteCarloHistoricalReturn(year: 1940, stocks: -0.1067, bonds: 0.054, cash: 0.0004),
        MonteCarloHistoricalReturn(year: 1941, stocks: -0.1277, bonds: -0.0202, cash: 0.0013),
        MonteCarloHistoricalReturn(year: 1942, stocks: 0.1917, bonds: 0.0229, cash: 0.0034),
        MonteCarloHistoricalReturn(year: 1943, stocks: 0.2506, bonds: 0.0249, cash: 0.0038),
        MonteCarloHistoricalReturn(year: 1944, stocks: 0.1903, bonds: 0.0258, cash: 0.0038),
        MonteCarloHistoricalReturn(year: 1945, stocks: 0.3582, bonds: 0.038, cash: 0.0038),
        MonteCarloHistoricalReturn(year: 1946, stocks: -0.0843, bonds: 0.0313, cash: 0.0038),
        MonteCarloHistoricalReturn(year: 1947, stocks: 0.052, bonds: 0.0092, cash: 0.006),
        MonteCarloHistoricalReturn(year: 1948, stocks: 0.057, bonds: 0.0195, cash: 0.0105),
        MonteCarloHistoricalReturn(year: 1949, stocks: 0.183, bonds: 0.0466, cash: 0.0112),
        MonteCarloHistoricalReturn(year: 1950, stocks: 0.3081, bonds: 0.0043, cash: 0.012),
        MonteCarloHistoricalReturn(year: 1951, stocks: 0.2368, bonds: -0.003, cash: 0.0152),
        MonteCarloHistoricalReturn(year: 1952, stocks: 0.1815, bonds: 0.0227, cash: 0.0172),
        MonteCarloHistoricalReturn(year: 1953, stocks: -0.0121, bonds: 0.0414, cash: 0.0189),
        MonteCarloHistoricalReturn(year: 1954, stocks: 0.5256, bonds: 0.0329, cash: 0.0094),
        MonteCarloHistoricalReturn(year: 1955, stocks: 0.326, bonds: -0.0134, cash: 0.0172),
        MonteCarloHistoricalReturn(year: 1956, stocks: 0.0744, bonds: -0.0226, cash: 0.0262),
        MonteCarloHistoricalReturn(year: 1957, stocks: -0.1046, bonds: 0.068, cash: 0.0322),
        MonteCarloHistoricalReturn(year: 1958, stocks: 0.4372, bonds: -0.021, cash: 0.0177),
        MonteCarloHistoricalReturn(year: 1959, stocks: 0.1206, bonds: -0.0265, cash: 0.0339),
        MonteCarloHistoricalReturn(year: 1960, stocks: 0.0034, bonds: 0.1164, cash: 0.0287),
        MonteCarloHistoricalReturn(year: 1961, stocks: 0.2664, bonds: 0.0206, cash: 0.0235),
        MonteCarloHistoricalReturn(year: 1962, stocks: -0.0881, bonds: 0.0569, cash: 0.0277),
        MonteCarloHistoricalReturn(year: 1963, stocks: 0.2261, bonds: 0.0168, cash: 0.0316),
        MonteCarloHistoricalReturn(year: 1964, stocks: 0.1642, bonds: 0.0373, cash: 0.0355),
        MonteCarloHistoricalReturn(year: 1965, stocks: 0.124, bonds: 0.0072, cash: 0.0395),
        MonteCarloHistoricalReturn(year: 1966, stocks: -0.0997, bonds: 0.0291, cash: 0.0486),
        MonteCarloHistoricalReturn(year: 1967, stocks: 0.238, bonds: -0.0158, cash: 0.0429),
        MonteCarloHistoricalReturn(year: 1968, stocks: 0.1081, bonds: 0.0327, cash: 0.0534),
        MonteCarloHistoricalReturn(year: 1969, stocks: -0.0824, bonds: -0.0501, cash: 0.0667),
        MonteCarloHistoricalReturn(year: 1970, stocks: 0.0356, bonds: 0.1675, cash: 0.0639),
        MonteCarloHistoricalReturn(year: 1971, stocks: 0.1422, bonds: 0.0979, cash: 0.0433),
        MonteCarloHistoricalReturn(year: 1972, stocks: 0.1876, bonds: 0.0282, cash: 0.0406),
        MonteCarloHistoricalReturn(year: 1973, stocks: -0.1431, bonds: 0.0366, cash: 0.0704),
        MonteCarloHistoricalReturn(year: 1974, stocks: -0.259, bonds: 0.0199, cash: 0.0785),
        MonteCarloHistoricalReturn(year: 1975, stocks: 0.37, bonds: 0.0361, cash: 0.0579),
        MonteCarloHistoricalReturn(year: 1976, stocks: 0.2383, bonds: 0.1598, cash: 0.0498),
        MonteCarloHistoricalReturn(year: 1977, stocks: -0.0698, bonds: 0.0129, cash: 0.0526),
        MonteCarloHistoricalReturn(year: 1978, stocks: 0.0651, bonds: -0.0078, cash: 0.0718),
        MonteCarloHistoricalReturn(year: 1979, stocks: 0.1852, bonds: 0.0067, cash: 0.1005),
        MonteCarloHistoricalReturn(year: 1980, stocks: 0.3174, bonds: -0.0299, cash: 0.1139),
        MonteCarloHistoricalReturn(year: 1981, stocks: -0.047, bonds: 0.082, cash: 0.1404),
        MonteCarloHistoricalReturn(year: 1982, stocks: 0.2042, bonds: 0.3281, cash: 0.1109),
        MonteCarloHistoricalReturn(year: 1983, stocks: 0.2234, bonds: 0.032, cash: 0.0895),
        MonteCarloHistoricalReturn(year: 1984, stocks: 0.0615, bonds: 0.1373, cash: 0.0992),
        MonteCarloHistoricalReturn(year: 1985, stocks: 0.3124, bonds: 0.2571, cash: 0.0772),
        MonteCarloHistoricalReturn(year: 1986, stocks: 0.1849, bonds: 0.2428, cash: 0.0615),
        MonteCarloHistoricalReturn(year: 1987, stocks: 0.0581, bonds: -0.0496, cash: 0.0596),
        MonteCarloHistoricalReturn(year: 1988, stocks: 0.1654, bonds: 0.0822, cash: 0.0689),
        MonteCarloHistoricalReturn(year: 1989, stocks: 0.3148, bonds: 0.1769, cash: 0.0839),
        MonteCarloHistoricalReturn(year: 1990, stocks: -0.0306, bonds: 0.0624, cash: 0.0775),
        MonteCarloHistoricalReturn(year: 1991, stocks: 0.3023, bonds: 0.15, cash: 0.0554),
        MonteCarloHistoricalReturn(year: 1992, stocks: 0.0749, bonds: 0.0936, cash: 0.0351),
        MonteCarloHistoricalReturn(year: 1993, stocks: 0.0997, bonds: 0.1421, cash: 0.0307),
        MonteCarloHistoricalReturn(year: 1994, stocks: 0.0133, bonds: -0.0804, cash: 0.0437),
        MonteCarloHistoricalReturn(year: 1995, stocks: 0.372, bonds: 0.2348, cash: 0.0566),
        MonteCarloHistoricalReturn(year: 1996, stocks: 0.2268, bonds: 0.0143, cash: 0.0515),
        MonteCarloHistoricalReturn(year: 1997, stocks: 0.331, bonds: 0.0994, cash: 0.052),
        MonteCarloHistoricalReturn(year: 1998, stocks: 0.2834, bonds: 0.1492, cash: 0.0491),
        MonteCarloHistoricalReturn(year: 1999, stocks: 0.2089, bonds: -0.0825, cash: 0.0478),
        MonteCarloHistoricalReturn(year: 2000, stocks: -0.0903, bonds: 0.1666, cash: 0.06),
        MonteCarloHistoricalReturn(year: 2001, stocks: -0.1185, bonds: 0.0557, cash: 0.0348),
        MonteCarloHistoricalReturn(year: 2002, stocks: -0.2197, bonds: 0.1512, cash: 0.0164),
        MonteCarloHistoricalReturn(year: 2003, stocks: 0.2836, bonds: 0.0038, cash: 0.0103),
        MonteCarloHistoricalReturn(year: 2004, stocks: 0.1074, bonds: 0.0449, cash: 0.014),
        MonteCarloHistoricalReturn(year: 2005, stocks: 0.0483, bonds: 0.0287, cash: 0.0322),
        MonteCarloHistoricalReturn(year: 2006, stocks: 0.1561, bonds: 0.0196, cash: 0.0485),
        MonteCarloHistoricalReturn(year: 2007, stocks: 0.0548, bonds: 0.1021, cash: 0.0448),
        MonteCarloHistoricalReturn(year: 2008, stocks: -0.3655, bonds: 0.201, cash: 0.014),
        MonteCarloHistoricalReturn(year: 2009, stocks: 0.2594, bonds: -0.1112, cash: 0.0015),
        MonteCarloHistoricalReturn(year: 2010, stocks: 0.1482, bonds: 0.0846, cash: 0.0014),
        MonteCarloHistoricalReturn(year: 2011, stocks: 0.021, bonds: 0.1604, cash: 0.0005),
        MonteCarloHistoricalReturn(year: 2012, stocks: 0.1589, bonds: 0.0297, cash: 0.0009),
        MonteCarloHistoricalReturn(year: 2013, stocks: 0.3215, bonds: -0.091, cash: 0.0006),
        MonteCarloHistoricalReturn(year: 2014, stocks: 0.1352, bonds: 0.1075, cash: 0.0003),
        MonteCarloHistoricalReturn(year: 2015, stocks: 0.0138, bonds: 0.0128, cash: 0.0005),
        MonteCarloHistoricalReturn(year: 2016, stocks: 0.1177, bonds: 0.0069, cash: 0.0032),
        MonteCarloHistoricalReturn(year: 2017, stocks: 0.2161, bonds: 0.028, cash: 0.0095),
        MonteCarloHistoricalReturn(year: 2018, stocks: -0.0423, bonds: -0.0002, cash: 0.0197),
        MonteCarloHistoricalReturn(year: 2019, stocks: 0.3121, bonds: 0.0964, cash: 0.0211),
        MonteCarloHistoricalReturn(year: 2020, stocks: 0.1802, bonds: 0.1133, cash: 0.0036),
        MonteCarloHistoricalReturn(year: 2021, stocks: 0.2847, bonds: -0.0442, cash: 0.0004),
        MonteCarloHistoricalReturn(year: 2022, stocks: -0.1804, bonds: -0.1783, cash: 0.0209),
        MonteCarloHistoricalReturn(year: 2023, stocks: 0.2606, bonds: 0.0388, cash: 0.0528),
        MonteCarloHistoricalReturn(year: 2024, stocks: 0.2488, bonds: -0.0164, cash: 0.0518),
        MonteCarloHistoricalReturn(year: 2025, stocks: 0.1778, bonds: 0.078, cash: 0.0421),
    ]
}

// MARK: - Output

struct MonteCarloPercentileBand: Equatable {
    /// 0 = starting point, 1..horizonYears = end of that year. Values in cents.
    let year: Int
    let p5: Int
    let p10: Int
    let p25: Int
    let p30: Int
    let p50: Int
    let p70: Int
    let p75: Int
    let p90: Int
}

struct MonteCarloData: Equatable {
    /// Fraction (0..1) of simulations that survived the full horizon.
    let successRate: Double
    let currentAge: Double
    let horizonYears: Int
    let simulationCount: Int
    let percentileBands: [MonteCarloPercentileBand]
}

// MARK: - PRNG

/// Exact port of upstream mulberry32 + Box-Muller normal sampler, so seeded
/// runs reproduce the web app's numbers bit for bit.
struct MonteCarloRandom {
    private var state: UInt32

    init(seed: UInt32) {
        state = seed
    }

    /// Uniform in [0, 1) (upstream mulberry32).
    mutating func next() -> Double {
        state = state &+ 0x6D2B79F5
        var mixed = (state ^ (state >> 15)) &* (state | 1)
        mixed = (mixed &+ ((mixed ^ (mixed >> 7)) &* (mixed | 61))) ^ mixed
        return Double(mixed ^ (mixed >> 14)) / 4294967296
    }

    /// Standard normal draw via the Box-Muller transform (upstream
    /// makeNormalSampler; the 1 - next() shift avoids log(0)).
    mutating func nextNormal() -> Double {
        let uniform1 = 1 - next()
        let uniform2 = next()
        return (-2 * Foundation.log(uniform1)).squareRoot() * Foundation.cos(2 * .pi * uniform2)
    }
}

// MARK: - Engine

/// Port of the webapp's monteCarloSimulation.ts drawdown engine. Pure and
/// deterministic for a given seed; upstream seeds with 1234 by default so
/// identical inputs always produce identical headline numbers.
///
/// Integrator wiring: pots may reference an account (`accountId`); pass the
/// current balance of those accounts (in cents) via `accountBalances` and the
/// pot's starting balance is replaced with `max(0, balance)`, mirroring
/// upstream useResolvedMonteCarloConfig. Pots without a match keep their
/// stored starting balance.
enum MonteCarloEngine {

    /// 1e14 minor units; keeps compounded results formatter-safe (upstream MAX_AMOUNT).
    static let maxAmount: Double = 100_000_000_000_000
    static let minSimulationCount = 1000.0
    static let maxSimulationCount = 10000.0
    static let minHorizonYears = 1
    static let maxHorizonYears = 100
    static let maxWithdrawalTaxRate = 0.75
    static let maxTaxBandRate = 0.99
    static let maxAnnualFeeRate = 0.1
    /// Upstream DEFAULT_SIMULATION_SEED.
    static let defaultSeed: UInt32 = 1234

    // MARK: Meta resolution (upstream monteCarloConfigFromMeta)

    static func config(from meta: MonteCarloMeta?) -> MonteCarloConfig {
        var config = MonteCarloConfig()
        if let potMetas = meta?.pots, !potMetas.isEmpty {
            config.pots = potMetas.enumerated().map { index, potMeta in
                var pot = MonteCarloPot(id: potMeta.id?.isEmpty == false ? potMeta.id! : "pot-\(index + 1)")
                pot.name = potMeta.name ?? pot.name
                pot.startingBalance = potMeta.startingBalance ?? pot.startingBalance
                pot.allocationPreset = potMeta.allocationPreset.flatMap(MonteCarloAllocationPreset.init) ?? pot.allocationPreset
                pot.expectedReturnMean = potMeta.expectedReturnMean ?? pot.expectedReturnMean
                pot.returnStdDev = potMeta.returnStdDev ?? pot.returnStdDev
                pot.accessAge = potMeta.accessAge
                pot.accountId = potMeta.accountId
                pot.withdrawalTaxRate = potMeta.withdrawalTaxRate ?? pot.withdrawalTaxRate
                pot.taxableFraction = potMeta.taxableFraction ?? pot.taxableFraction
                pot.annualFeeFixed = potMeta.annualFeeFixed ?? pot.annualFeeFixed
                pot.feeAdjustsWithInflation = potMeta.feeAdjustsWithInflation ?? pot.feeAdjustsWithInflation
                pot.annualFeeRate = potMeta.annualFeeRate ?? pot.annualFeeRate
                return pot
            }
        }
        config.withdrawalStrategy = meta?.withdrawalStrategy.flatMap(MonteCarloWithdrawalStrategy.init) ?? config.withdrawalStrategy
        config.returnModel = meta?.returnModel.flatMap(MonteCarloReturnModel.init) ?? config.returnModel
        if let ruleMeta = meta?.withdrawalRule {
            var rule = MonteCarloWithdrawalRule()
            rule.type = ruleMeta.type.flatMap(MonteCarloWithdrawalRuleType.init) ?? rule.type
            rule.prosperityTriggerPct = ruleMeta.prosperityTriggerPct ?? rule.prosperityTriggerPct
            rule.prosperityIncreasePct = ruleMeta.prosperityIncreasePct ?? rule.prosperityIncreasePct
            rule.preservationTriggerPct = ruleMeta.preservationTriggerPct ?? rule.preservationTriggerPct
            rule.preservationCutPct = ruleMeta.preservationCutPct ?? rule.preservationCutPct
            rule.balanceThresholdMultiple = ruleMeta.balanceThresholdMultiple ?? rule.balanceThresholdMultiple
            rule.consecutiveYears = ruleMeta.consecutiveYears ?? rule.consecutiveYears
            rule.ratchetIncreasePct = ruleMeta.ratchetIncreasePct ?? rule.ratchetIncreasePct
            rule.floorPct = ruleMeta.floorPct ?? rule.floorPct
            rule.ceilingPct = ruleMeta.ceilingPct ?? rule.ceilingPct
            rule.upperRateThreshold = ruleMeta.upperRateThreshold ?? rule.upperRateThreshold
            rule.upperCutPct = ruleMeta.upperCutPct ?? rule.upperCutPct
            rule.lowerRateThreshold = ruleMeta.lowerRateThreshold ?? rule.lowerRateThreshold
            rule.lowerIncreasePct = ruleMeta.lowerIncreasePct ?? rule.lowerIncreasePct
            config.withdrawalRule = rule
        }
        config.minimumWithdrawal = meta?.minimumWithdrawal ?? config.minimumWithdrawal
        if let phaseMetas = meta?.spendingPhases, !phaseMetas.isEmpty {
            config.spendingPhases = phaseMetas.enumerated().map { index, phaseMeta in
                var phase = MonteCarloSpendingPhase(id: phaseMeta.id?.isEmpty == false ? phaseMeta.id! : "phase-\(index + 1)")
                phase.name = phaseMeta.name ?? phase.name
                phase.fromAge = phaseMeta.fromAge
                phase.annualWithdrawal = phaseMeta.annualWithdrawal ?? phase.annualWithdrawal
                return phase
            }
        }
        // Absent = default; explicit null = flat withdrawals
        if let inflationMean = meta?.inflationMean {
            config.inflationMean = inflationMean
        }
        config.inflationStdDev = meta?.inflationStdDev ?? config.inflationStdDev
        config.taxModel = meta?.taxModel.flatMap(MonteCarloTaxModel.init) ?? config.taxModel
        if let bandMetas = meta?.taxBands, !bandMetas.isEmpty {
            config.taxBands = bandMetas.enumerated().map { index, bandMeta in
                var band = MonteCarloTaxBand(id: bandMeta.id?.isEmpty == false ? bandMeta.id! : "band-\(index + 1)")
                band.from = bandMeta.from ?? band.from
                band.rate = bandMeta.rate ?? band.rate
                return band
            }
        }
        config.currentAge = meta?.currentAge ?? config.currentAge
        config.targetAge = meta?.targetAge ?? config.targetAge
        config.simulationCount = meta?.simulationCount ?? config.simulationCount
        return config
    }

    /// Simulated years, derived from the configured ages (upstream
    /// getMonteCarloHorizonYears).
    static func horizonYears(currentAge: Double, targetAge: Double) -> Int {
        // Clamp before converting so absurd ages can't overflow Int
        let years = min(Double(maxHorizonYears), max(Double(minHorizonYears), (targetAge - currentAge).rounded()))
        return Int(years)
    }

    /// Card entry point: resolves account-linked pots then simulates in
    /// today's money, as the dashboard card does upstream (MonteCarloCard.tsx).
    static func compute(
        meta: MonteCarloMeta?,
        accountBalances: [String: Int] = [:],
        seed: UInt32 = defaultSeed
    ) -> MonteCarloData {
        var resolved = Self.config(from: meta)
        // Upstream useResolvedMonteCarloConfig: linked pots take the
        // account's live balance, falling back to the stored one
        resolved.pots = resolved.pots.map { pot in
            guard let accountId = pot.accountId, let balance = accountBalances[accountId] else { return pot }
            var linked = pot
            linked.startingBalance = Double(max(0, balance))
            return linked
        }
        return simulate(config: resolved, seed: seed, deflateToTodaysMoney: true)
    }

    // MARK: Simulation (upstream runMonteCarloSimulation)

    /// Each year, in each simulation: the withdrawal is taken at the start of
    /// the year across the pots that have reached their access age; if the
    /// accessible pots can't cover it the simulation is marked depleted for
    /// that year; otherwise each pot earns that year's return. Returns are
    /// nominal - inflation only grows withdrawals.
    static func simulate(
        config: MonteCarloConfig,
        seed: UInt32 = defaultSeed,
        deflateToTodaysMoney: Bool = false,
        historicalReturns: [MonteCarloHistoricalReturn]? = nil
    ) -> MonteCarloData {
        func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
            Swift.min(high, Swift.max(low, value))
        }

        let pots = config.pots.isEmpty ? [MonteCarloPot(id: "pot-1")] : config.pots
        let potCount = pots.count
        let potStartBalances = pots.map { clamp($0.startingBalance, 0, maxAmount) }
        let potMeans = pots.map { $0.expectedReturnMean }
        let potStdDevs = pots.map { Swift.max(0, $0.returnStdDev) }
        let isSequential = config.withdrawalStrategy == .sequential
        let isBestPerformer = config.withdrawalStrategy == .bestPerformer
        let isTargetMix = config.withdrawalStrategy == .targetMix
        var previousReturns = [Double](repeating: 0, count: potCount)
        var drainOrder = Array(0..<potCount)
        var potIdealBalances = [Double](repeating: 0, count: potCount)
        var potTakes = [Double](repeating: 0, count: potCount)

        // First simulation year (1-based) in which each pot can fund
        // withdrawals; the year-y withdrawal happens at age currentAge + (y - 1)
        let potAccessFromYear: [Int] = pots.map { pot in
            guard let accessAge = pot.accessAge else { return 1 }
            // Clamp before converting so absurd ages can't overflow Int; the
            // year is only ever compared against year <= maxHorizonYears
            let offset = clamp((accessAge - config.currentAge).rounded(), 0, Double(maxHorizonYears) + 1)
            return Swift.max(1, Int(offset) + 1)
        }

        // --- Tax ------------------------------------------------------------
        let taxModel = config.taxModel
        let potTaxRates = pots.map { clamp($0.withdrawalTaxRate, 0, maxWithdrawalTaxRate) }
        let potTaxableFractions = pots.map { clamp($0.taxableFraction, 0, 1) }
        // Bands sorted ascending (stable, like JS sort), with a guaranteed
        // 0-threshold first band so income below the first threshold is untaxed
        var taxBands = config.taxBands
            .map { (from: clamp($0.from, 0, maxAmount), rate: clamp($0.rate, 0, maxTaxBandRate)) }
            .enumerated()
            .sorted { ($0.element.from, $0.offset) < ($1.element.from, $1.offset) }
            .map(\.element)
        if taxBands.isEmpty || taxBands[0].from > 0 {
            taxBands.insert((from: 0, rate: 0), at: 0)
        }
        let hasTax = taxModel == .bands
            ? taxBands.contains { $0.rate > 0 } && potTaxableFractions.contains { $0 > 0 }
            : potTaxRates.contains { $0 > 0 }

        // --- Fees -----------------------------------------------------------
        let potFeeFixed = pots.map { clamp($0.annualFeeFixed, 0, maxAmount) }
        let potFeeAdjusts = pots.map { $0.feeAdjustsWithInflation }
        let potFeeRates = pots.map { clamp($0.annualFeeRate, 0, maxAnnualFeeRate) }
        let hasFees = potFeeFixed.contains { $0 > 0 } || potFeeRates.contains { $0 > 0 }

        // Worst-case share of a gross withdrawal lost to tax; used to skip the
        // per-year shortfall precheck when capacity is comfortably sufficient
        let maxTaxRate = taxModel == .bands
            ? taxBands.map(\.rate).reduce(0, Swift.max)
            : potTaxRates.reduce(0, Swift.max)
        let minNetFactor = 1 - maxTaxRate

        // Progressive tax on an annual taxable income, in today's money
        func bandTax(_ taxableIncome: Double) -> Double {
            var tax = 0.0
            for bandIndex in 0..<taxBands.count {
                if taxableIncome <= taxBands[bandIndex].from {
                    break
                }
                let upper = bandIndex + 1 < taxBands.count ? taxBands[bandIndex + 1].from : .infinity
                tax += taxBands[bandIndex].rate * (Swift.min(taxableIncome, upper) - taxBands[bandIndex].from)
            }
            return tax
        }

        // Tax due on the takes currently in potTakes. Band thresholds are in
        // today's money, so taxable income is deflated by the replay's
        // inflation path before banding
        func taxForTakes(_ cumulativeInflationNow: Double) -> Double {
            if !hasTax {
                return 0
            }
            if taxModel == .flat {
                var tax = 0.0
                for potIndex in 0..<potCount {
                    tax += potTakes[potIndex] * potTaxRates[potIndex]
                }
                return tax
            }
            var taxable = 0.0
            for potIndex in 0..<potCount {
                taxable += potTakes[potIndex] * potTaxableFractions[potIndex]
            }
            return bandTax(taxable / cumulativeInflationNow) * cumulativeInflationNow
        }

        var potBalances = [Double](repeating: 0, count: potCount)

        // Split a gross withdrawal across pots per the configured strategy,
        // writing each pot's take into potTakes (upstream computeTakes)
        func computeTakes(_ grossTotal: Double, _ year: Int, _ accessibleTotal: Double, _ lastAccessibleIndex: Int) {
            for potIndex in 0..<potCount {
                potTakes[potIndex] = 0
            }
            if grossTotal <= 0 || accessibleTotal <= 0 {
                return
            }
            if isSequential || isBestPerformer {
                if isBestPerformer {
                    // Drain the pot with the highest return last year first;
                    // ties fall back to the listed order (JS stable sort)
                    for potIndex in 0..<potCount {
                        drainOrder[potIndex] = potIndex
                    }
                    drainOrder.sort { potA, potB in
                        previousReturns[potA] != previousReturns[potB]
                            ? previousReturns[potA] > previousReturns[potB]
                            : potA < potB
                    }
                }
                var remaining = grossTotal
                for orderIndex in 0..<potCount where remaining > 0 {
                    let potIndex = isBestPerformer ? drainOrder[orderIndex] : orderIndex
                    if year < potAccessFromYear[potIndex] {
                        continue
                    }
                    let take = Swift.min(potBalances[potIndex], remaining)
                    potTakes[potIndex] = take
                    remaining -= take
                }
            } else if isTargetMix {
                // Withdraw so the accessible pots move back toward their
                // target mix (weights = shares of the starting balances)
                var targetAccessible = 0.0
                for potIndex in 0..<potCount where year >= potAccessFromYear[potIndex] {
                    targetAccessible += potStartBalances[potIndex]
                }
                let remainingTotal = accessibleTotal - grossTotal
                for potIndex in 0..<potCount {
                    drainOrder[potIndex] = potIndex
                    potIdealBalances[potIndex] =
                        year >= potAccessFromYear[potIndex] && targetAccessible > 0
                            ? (potStartBalances[potIndex] / targetAccessible) * remainingTotal
                            : 0
                }
                drainOrder.sort { potA, potB in
                    let excessA = potBalances[potA] - potIdealBalances[potA]
                    let excessB = potBalances[potB] - potIdealBalances[potB]
                    return excessA != excessB ? excessA > excessB : potA < potB
                }
                var remaining = grossTotal
                for orderIndex in 0..<potCount where remaining > 0 {
                    let potIndex = drainOrder[orderIndex]
                    if year < potAccessFromYear[potIndex] {
                        continue
                    }
                    let excess = potBalances[potIndex] - potIdealBalances[potIndex]
                    if excess <= 0 {
                        continue
                    }
                    let take = Swift.min(remaining, Swift.min(potBalances[potIndex], excess))
                    potTakes[potIndex] = take
                    remaining -= take
                }
                // Float-drift safety net: drain any accessible pot for
                // whatever tiny residue the excess passes left behind
                for potIndex in 0..<potCount where remaining > 0 {
                    if year < potAccessFromYear[potIndex] {
                        continue
                    }
                    let take = Swift.min(potBalances[potIndex] - potTakes[potIndex], remaining)
                    potTakes[potIndex] += take
                    remaining -= take
                }
            } else {
                // Proportional split across accessible pots; the last
                // accessible pot takes the remainder (no float drift)
                var remaining = grossTotal
                for potIndex in 0..<Swift.max(0, lastAccessibleIndex) {
                    if year < potAccessFromYear[potIndex] {
                        continue
                    }
                    let take = grossTotal * (potBalances[potIndex] / accessibleTotal)
                    potTakes[potIndex] = take
                    remaining -= take
                }
                if lastAccessibleIndex >= 0 {
                    potTakes[lastAccessibleIndex] = remaining
                }
            }
        }

        let returnModel = config.returnModel
        let history = (historicalReturns?.isEmpty == false) ? historicalReturns! : MonteCarloHistoricalReturn.all
        let historyCount = history.count

        // For historical models, each preset pot gets the blended return of
        // its asset mix in every historical year; 'custom' pots keep using
        // normal draws around their own mean/volatility
        let potHistoricalReturns: [[Double]?] = pots.map { pot in
            guard returnModel != .normal, let weights = pot.allocationPreset.assetWeights else {
                return nil
            }
            return history.map { weights.stocks * $0.stocks + weights.bonds * $0.bonds + weights.cash * $0.cash }
        }
        let hasNormalDrawPot = potHistoricalReturns.contains { $0 == nil }

        let inflationMean = config.inflationMean
        let inflationStdDev = inflationMean != nil ? Swift.max(0, config.inflationStdDev) : 0
        let horizonYears = Self.horizonYears(currentAge: config.currentAge, targetAge: config.targetAge)

        // The planned spending path in today's money: the active phase's
        // amount for every year (phases ordered by starting age, no-age first,
        // stable like upstream sortMonteCarloSpendingPhases)
        let spendingPhases = (config.spendingPhases.isEmpty
            ? [MonteCarloSpendingPhase(id: "phase-1")]
            : config.spendingPhases)
            .enumerated()
            .sorted { ($0.element.fromAge ?? -.infinity, $0.offset) < ($1.element.fromAge ?? -.infinity, $1.offset) }
            .map(\.element)
        var plannedTodayByYear = [Double](repeating: 0, count: horizonYears + 1)
        for year in 1...horizonYears {
            let age = config.currentAge + Double(year - 1)
            var amount = clamp(spendingPhases[0].annualWithdrawal, 0, maxAmount)
            for phase in spendingPhases {
                if phase.fromAge == nil || phase.fromAge! <= age {
                    amount = clamp(phase.annualWithdrawal, 0, maxAmount)
                } else {
                    break
                }
            }
            plannedTodayByYear[year] = amount
        }

        let deflate = deflateToTodaysMoney && inflationMean != nil
        // Sequence replay runs exactly one scenario per historical start year
        let simulationCount = returnModel == .historicalSequence
            ? historyCount
            : Int(clamp(config.simulationCount.rounded(), minSimulationCount, maxSimulationCount))

        var random = MonteCarloRandom(seed: seed)

        // Year-major balance buffers (totals across pots)
        var balancesByYear = [[Double]](repeating: [Double](repeating: 0, count: simulationCount), count: horizonYears + 1)
        var depletionCounts = [Int](repeating: 0, count: horizonYears + 1)
        var survivedCount = 0

        let startingTotal = potStartBalances.reduce(0, +)
        let rule = config.withdrawalRule
        let minimumWithdrawal = clamp(config.minimumWithdrawal, 0, maxAmount)

        // Keep every emitted amount formatter-safe; absurd configs flat-line
        // at the cap instead of overflowing (upstream toSafeAmount)
        let maxEmitted = Double(1 << 50)  // 2^50, upstream maxEmitted
        func toSafeAmount(_ value: Double) -> Double {
            clamp(value, -maxEmitted, maxEmitted)
        }

        // Starting wealth accessible in each simulated year: withdrawal rules
        // measure rates against pots that can actually fund spending
        var accessibleStartByYear = [Double](repeating: 0, count: horizonYears + 1)
        for year in 1...horizonYears {
            var accessibleStart = 0.0
            for potIndex in 0..<potCount where year >= potAccessFromYear[potIndex] {
                accessibleStart += potStartBalances[potIndex]
            }
            accessibleStartByYear[year] = accessibleStart
        }

        let initialRate = accessibleStartByYear[1] > 0 ? plannedTodayByYear[1] / accessibleStartByYear[1] : 0

        for simulationIndex in 0..<simulationCount {
            potBalances = potStartBalances
            for potIndex in 0..<potCount {
                previousReturns[potIndex] = 0
            }
            var total = startingTotal
            // Cuts/raises from the withdrawal rule compound here, on top of
            // the planned spending path
            var adjustmentFactor = 1.0
            // This replay's realized inflation path
            var cumulativeInflation = 1.0
            var ratchetStreak = 0.0
            var depleted = false

            balancesByYear[0][simulationIndex] = toSafeAmount(total)

            for year in 1...horizonYears {
                if depleted {
                    // Post-depletion years stay at zero
                    continue
                }
                let planned = plannedTodayByYear[year] * cumulativeInflation
                var withdrawal: Double

                // Only pots that have reached their access age can fund this
                // year's withdrawal; locked pots stay invested but untouchable
                var accessibleTotal = 0.0
                var lastAccessibleIndex = -1
                for potIndex in 0..<potCount where year >= potAccessFromYear[potIndex] {
                    accessibleTotal += potBalances[potIndex]
                    lastAccessibleIndex = potIndex
                }

                // Apply the dynamic withdrawal rule before taking this year's
                // withdrawal (from year 2 - year 1 always uses the plan).
                // Rules evaluate accessible wealth only.
                if year > 1 && rule.type == .floorCeiling {
                    // Recompute rule: a fixed share of the accessible balance,
                    // kept within limits around the planned spending
                    withdrawal = clamp(
                        initialRate * accessibleTotal,
                        planned * (1 - rule.floorPct),
                        planned * (1 + rule.ceilingPct)
                    )
                } else {
                    if year > 1 && rule.type != .none && accessibleTotal > 0 && accessibleStartByYear[year] > 0 {
                        let currentRate = (planned * adjustmentFactor) / accessibleTotal
                        switch rule.type {
                        case .guardrails:
                            // Drift is measured against the planned spending
                            // path, so a deliberate phase change doesn't read
                            // as a trigger - only market-driven drift does
                            let referenceRate = plannedTodayByYear[year] / accessibleStartByYear[year]
                            if currentRate > referenceRate * (1 + rule.preservationTriggerPct) {
                                adjustmentFactor *= 1 - rule.preservationCutPct
                            } else if currentRate < referenceRate * (1 - rule.prosperityTriggerPct) {
                                adjustmentFactor *= 1 + rule.prosperityIncreasePct
                            }
                        case .ratcheting:
                            if accessibleTotal > accessibleStartByYear[year] * rule.balanceThresholdMultiple {
                                ratchetStreak += 1
                                if ratchetStreak >= rule.consecutiveYears {
                                    adjustmentFactor *= 1 + rule.ratchetIncreasePct
                                    ratchetStreak = 0
                                }
                            } else {
                                ratchetStreak = 0
                            }
                        case .boundaries:
                            if currentRate > rule.upperRateThreshold {
                                adjustmentFactor *= 1 - rule.upperCutPct
                            } else if currentRate < rule.lowerRateThreshold {
                                adjustmentFactor *= 1 + rule.lowerIncreasePct
                            }
                        case .none, .floorCeiling:
                            break
                        }
                    }
                    withdrawal = planned * adjustmentFactor
                }
                // The minimum floor guards against rule-driven cuts, so it
                // only applies with an active rule in years with planned
                // spending; like the phase amounts it's in today's money
                let minimumThisYear = minimumWithdrawal * cumulativeInflation
                if rule.type != .none && minimumWithdrawal > 0 && planned > 0 && withdrawal < minimumThisYear {
                    withdrawal = minimumThisYear
                }

                // The spending requirement is net of tax; the gross that
                // leaves the pots must deliver it
                let netRequired = withdrawal
                var fundingShortfall = false

                // Net capacity: what withdrawing every accessible penny would
                // actually deliver after tax
                var accessibleNetCapacity = accessibleTotal
                if hasTax && accessibleTotal * minNetFactor <= netRequired {
                    computeTakes(accessibleTotal, year, accessibleTotal, lastAccessibleIndex)
                    accessibleNetCapacity = accessibleTotal - taxForTakes(cumulativeInflation)
                }

                if accessibleNetCapacity <= netRequired {
                    fundingShortfall = true
                    // The accessible pots can't cover this year's spending
                    // (locked pots may still hold money)
                    for potIndex in 0..<potCount {
                        potBalances[potIndex] = 0
                    }
                    total = 0
                    depleted = true
                    depletionCounts[year] += 1
                } else {
                    // Solve the gross withdrawal that delivers the net
                    // requirement: g = net + tax(takes(g)). Tax is piecewise
                    // linear in g, so this fixed point converges geometrically
                    var grossTotal = netRequired
                    if hasTax {
                        for _ in 0..<40 {
                            computeTakes(grossTotal, year, accessibleTotal, lastAccessibleIndex)
                            let next = netRequired + taxForTakes(cumulativeInflation)
                            if abs(next - grossTotal) <= 1e-7 * Swift.max(1, next) {
                                grossTotal = next
                                break
                            }
                            grossTotal = next
                        }
                        grossTotal = Swift.min(grossTotal, accessibleTotal)
                    }

                    computeTakes(grossTotal, year, accessibleTotal, lastAccessibleIndex)
                    for potIndex in 0..<potCount {
                        potBalances[potIndex] -= potTakes[potIndex]
                    }

                    // Every pot experiences the same market year: historical
                    // models pick one history year for all pots, and
                    // normally-drawn pots share one market shock scaled by
                    // their own volatility
                    var historyIndex = -1
                    if returnModel == .historicalBootstrap {
                        historyIndex = Int(random.next() * Double(historyCount))
                    } else if returnModel == .historicalSequence {
                        historyIndex = (simulationIndex + year - 1) % historyCount
                    }
                    let marketShock = hasNormalDrawPot ? random.nextNormal() : 0

                    total = 0
                    for potIndex in 0..<potCount {
                        if potBalances[potIndex] > 0 {
                            let yearReturn: Double
                            if let blended = potHistoricalReturns[potIndex], historyIndex >= 0 {
                                yearReturn = blended[historyIndex]
                            } else {
                                yearReturn = potMeans[potIndex] + potStdDevs[potIndex] * marketShock
                            }
                            previousReturns[potIndex] = yearReturn
                            potBalances[potIndex] *= 1 + yearReturn
                            if potBalances[potIndex] <= 0 {
                                // A sub-(-100%) return draw wiped this pot out
                                potBalances[potIndex] = 0
                            }
                        }
                        total += potBalances[potIndex]
                    }
                    if total <= 0 {
                        total = 0
                        depleted = true
                        depletionCounts[year] += 1
                    }
                }

                // Realize this year's inflation, drawing a random rate when
                // volatility is set (fixed mean otherwise)
                if let inflationMean {
                    let yearInflation = inflationStdDev > 0
                        ? Swift.max(-0.9, inflationMean + inflationStdDev * random.nextNormal())
                        : inflationMean
                    cumulativeInflation *= 1 + yearInflation
                }

                // Management fees come out at the end of the year, after
                // growth and inflation; fees can deplete a plan on their own
                if hasFees && !fundingShortfall && total > 0 {
                    for potIndex in 0..<potCount where potBalances[potIndex] > 0 {
                        let fee = potBalances[potIndex] * potFeeRates[potIndex]
                            + potFeeFixed[potIndex] * (potFeeAdjusts[potIndex] ? cumulativeInflation : 1)
                        let charged = Swift.min(potBalances[potIndex], fee)
                        potBalances[potIndex] -= charged
                    }
                    total = 0
                    for potIndex in 0..<potCount {
                        total += potBalances[potIndex]
                    }
                    if total <= 0 {
                        total = 0
                        depleted = true
                        depletionCounts[year] += 1
                    }
                }
                let endDeflator = deflate ? 1 / cumulativeInflation : 1

                // Store this replay's balance, in today's money when deflating
                balancesByYear[year][simulationIndex] = toSafeAmount(total * endDeflator)
            }

            if !depleted {
                survivedCount += 1
            }
        }

        func percentileOfSorted(_ sorted: [Double], _ percentile: Double) -> Double {
            let position = Double(sorted.count - 1) * percentile
            let lower = Int(position.rounded(.down))
            let upper = Int(position.rounded(.up))
            if lower == upper {
                return sorted[lower]
            }
            let weight = position - Double(lower)
            return sorted[lower] * (1 - weight) + sorted[upper] * weight
        }

        var percentileBands: [MonteCarloPercentileBand] = []
        for year in 0...horizonYears {
            let sorted = balancesByYear[year].sorted()
            func p(_ percentile: Double) -> Int {
                Int(percentileOfSorted(sorted, percentile).rounded())
            }
            percentileBands.append(MonteCarloPercentileBand(
                year: year,
                p5: p(0.05), p10: p(0.1), p25: p(0.25), p30: p(0.3),
                p50: p(0.5), p70: p(0.7), p75: p(0.75), p90: p(0.9)
            ))
        }

        return MonteCarloData(
            successRate: Double(survivedCount) / Double(simulationCount),
            currentAge: config.currentAge,
            horizonYears: horizonYears,
            simulationCount: simulationCount,
            percentileBands: percentileBands
        )
    }
}
