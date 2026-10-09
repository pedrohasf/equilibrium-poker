import Foundation

/// Metrics for one answer to one decision.
public struct DecisionScore: Hashable, Sendable {
    public var decisionId: String
    public var choice: Int?
    public var valid: Bool
    /// best EV − chosen EV, bb (≥ 0). Invalid answers lose the full spread (best − worst).
    public var evLoss: Double
    /// `evLoss` as a fraction of the pot at the decision.
    public var evLossPot: Double
    /// 1 − loss / (best − worst), in [0, 1]. Decisions where every action is within `Scoring.bestTolerance`
    /// of the pot of the best score 1 for any valid answer.
    public var score: Double
    /// Within `Scoring.bestTolerance` of the best EV.
    public var isBest: Bool
    /// Chosen action is played at least `Scoring.approvedFrequency` of the time by GTO with this hand.
    public var approved: Bool
    /// EV loss above `Scoring.blunderThreshold` of the pot.
    public var blunder: Bool
    /// GTO frequency of the chosen action (0 if invalid).
    public var gtoFrequency: Double

    // Distribution metrics — set for players that report action probabilities (decision models,
    // sampled GTO). Invalid answers from such players score as the worst case (spread / 1 / 0).
    /// Σ p(a)·loss(a), bb: EV lost if the player *played* its distribution instead of the argmax.
    public var mixedEVLoss: Double? = nil
    /// `mixedEVLoss` as a fraction of the pot.
    public var mixedEVLossPot: Double? = nil
    /// Total-variation distance ½Σ|p − gto| to the equilibrium strategy of hero's hand, in [0, 1].
    public var tvDistance: Double? = nil
    /// Probability mass the player puts on best-EV actions (within `bestTolerance`).
    public var bestActionProbability: Double? = nil
    /// Model-reported confidence in its choice.
    public var confidence: Double? = nil

    public var hasDistribution: Bool { mixedEVLoss != nil }
}

/// Aggregate over a set of decisions.
public struct ScoreBucket: Codable, Hashable, Sendable {
    public var n: Int
    public var meanEVLoss: Double
    public var meanEVLossCI: Double
    public var meanEVLossPot: Double
    public var meanEVLossPotCI: Double
    /// 0–100.
    public var gtoScore: Double
    public var gtoScoreCI: Double
    public var accuracy: Double
    public var approvedRate: Double
    public var blunderRate: Double
    public var invalidRate: Double
    /// Decisions with distribution metrics (0 for argmax-only players; then the fields below are nil).
    public var distributionN: Int = 0
    public var meanMixedEVLoss: Double? = nil
    public var meanMixedEVLossPot: Double? = nil
    public var meanMixedEVLossPotCI: Double? = nil
    public var meanTVDistance: Double? = nil
    public var meanTVDistanceCI: Double? = nil
    /// Calibration: mean probability assigned to the best-EV action(s).
    public var meanBestActionProbability: Double? = nil
    public var meanConfidence: Double? = nil

    public static let empty = ScoreBucket(n: 0, meanEVLoss: 0, meanEVLossCI: 0, meanEVLossPot: 0, meanEVLossPotCI: 0,
                                          gtoScore: 0, gtoScoreCI: 0, accuracy: 0, approvedRate: 0, blunderRate: 0, invalidRate: 0)
}

/// Leaderboard row for one run.
public struct ModelScore: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var model: String
    public var label: String
    public var kind: PlayerKind
    public var answered: Int
    public var total: Int
    public var overall: ScoreBucket
    public var byStreet: [String: ScoreBucket]
    public var byType: [String: ScoreBucket]
    public var meanLatency: Double
    public var totalCost: Double
    public var promptTokens: Int
    public var completionTokens: Int
    /// Variant id (decision models) — also part of `label`.
    public var variant: String? = nil
    /// Hands suites: postflop bb/100 lost vs GTO (see `HandMetrics`).
    public var perHand: HandMetrics? = nil

    public var isComplete: Bool { answered >= total }
    public var totalTokens: Int { promptTokens + completionTokens }
    public var isBaseline: Bool { kind == .baseline }
    public var isDecisionModel: Bool { kind == .decisionModel }
    public var isDerived: Bool { kind == .derived }
    public var hasDistribution: Bool { overall.distributionN > 0 }
}

public enum Scoring {
    /// An answer counts as "best" when within this fraction of the pot of the top EV
    /// (solutions are only converged to ~0.3–0.5% pot, so exact ties are meaningless).
    public static let bestTolerance = 0.0025
    public static let approvedFrequency = 0.10
    public static let blunderThreshold = 0.25

    // MARK: Distribution metrics (pure)

    /// Clamps negatives / non-finite values to 0 and rescales to sum 1; nil if nothing positive is left.
    public static func normalized(_ p: [Double]) -> [Double]? {
        let c = p.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let sum = c.reduce(0, +)
        guard sum > 0 else { return nil }
        return c.map { $0 / sum }
    }

    /// Σ p(a)·loss(a) in bb for a (normalised) distribution over the decision's actions.
    public static func mixedEVLoss(_ d: Decision, probabilities p: [Double]) -> Double {
        zip(p, d.actions.indices).reduce(0) { $0 + $1.0 * d.evLoss($1.1) }
    }

    /// ½Σ|p − q| over aligned vectors (missing entries count as 0).
    public static func totalVariation(_ p: [Double], _ q: [Double]) -> Double {
        (0..<max(p.count, q.count)).reduce(0) { acc, i in
            acc + abs((i < p.count ? p[i] : 0) - (i < q.count ? q[i] : 0))
        } / 2
    }

    /// Mass on actions within `bestTolerance` of the pot of the best EV.
    public static func bestActionProbability(_ d: Decision, probabilities p: [Double]) -> Double {
        let tol = bestTolerance * max(d.pot, 1e-9)
        return zip(p, d.actions.indices).reduce(0) { $0 + (d.evLoss($1.1) <= tol ? $1.0 : 0) }
    }

    /// Argmax metrics, plus distribution metrics when `probabilities` is given or `probabilistic`
    /// is set (a probabilistic player's invalid answer scores as the worst distribution).
    public static func score(_ d: Decision, choice: Int?, probabilities: [Double]? = nil, probabilistic: Bool = false,
                             confidence: Double? = nil) -> DecisionScore {
        var s = score(d, choice: choice)
        let pot = max(d.pot, 1e-9)
        if s.valid, let raw = probabilities, raw.count == d.actions.count, let p = normalized(raw) {
            let m = mixedEVLoss(d, probabilities: p)
            s.mixedEVLoss = m
            s.mixedEVLossPot = m / pot
            s.tvDistance = normalized(d.strategy).map { totalVariation(p, $0) }
            s.bestActionProbability = bestActionProbability(d, probabilities: p)
            s.confidence = confidence
        } else if probabilistic || probabilities != nil {
            s.mixedEVLoss = d.evSpread
            s.mixedEVLossPot = d.evSpread / pot
            s.tvDistance = 1
            s.bestActionProbability = 0
        }
        return s
    }

    /// Scores one stored result. Old sampled-GTO runs (no stored probabilities) use the hand's strategy.
    public static func score(_ d: Decision, result r: DecisionResult, run: BenchmarkRun) -> DecisionScore {
        let probs = r.actionProbabilities ?? (run.model == Baseline.gto.id ? d.strategy : nil)
        return score(d, choice: r.choice, probabilities: probs, probabilistic: run.kind.isProbabilistic, confidence: r.confidence)
    }

    public static func score(_ d: Decision, choice: Int?) -> DecisionScore {
        let valid = choice.map { d.actions.indices.contains($0) } ?? false
        let c = valid ? choice : nil
        let loss = d.evLoss(c)
        let pot = max(d.pot, 1e-9)
        let spread = d.evSpread
        // Decisions whose actions are all within the tie tolerance score 1 for any valid action (hands suites keep
        // such near-trivial spots; their spread is solver noise). Invalid answers still score 0.
        let s = spread > bestTolerance * pot ? max(0, min(1, 1 - loss / spread)) : (valid ? 1 : 0)
        let freq = c.map { d.strategy.indices.contains($0) ? d.strategy[$0] : 0 } ?? 0
        return DecisionScore(decisionId: d.id, choice: c, valid: valid, evLoss: loss, evLossPot: loss / pot, score: s,
                             isBest: valid && loss <= bestTolerance * pot, approved: valid && freq >= approvedFrequency,
                             blunder: loss / pot > blunderThreshold, gtoFrequency: freq)
    }

    /// Mean and 95% confidence half-width (normal approximation, sample standard deviation).
    public static func meanCI(_ xs: [Double]) -> (mean: Double, ci: Double) {
        guard !xs.isEmpty else { return (0, 0) }
        let n = Double(xs.count)
        let mean = xs.reduce(0, +) / n
        guard xs.count > 1 else { return (mean, 0) }
        let variance = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / (n - 1)
        return (mean, 1.96 * (variance / n).squareRoot())
    }

    public static func bucket(_ scores: [DecisionScore]) -> ScoreBucket {
        guard !scores.isEmpty else { return .empty }
        let n = Double(scores.count)
        let loss = meanCI(scores.map(\.evLoss))
        let lossPot = meanCI(scores.map(\.evLossPot))
        let gto = meanCI(scores.map { $0.score * 100 })
        func rate(_ f: (DecisionScore) -> Bool) -> Double { Double(scores.filter(f).count) / n }
        var b = ScoreBucket(n: scores.count, meanEVLoss: loss.mean, meanEVLossCI: loss.ci, meanEVLossPot: lossPot.mean,
                            meanEVLossPotCI: lossPot.ci, gtoScore: gto.mean, gtoScoreCI: gto.ci, accuracy: rate(\.isBest),
                            approvedRate: rate(\.approved), blunderRate: rate(\.blunder), invalidRate: rate { !$0.valid })
        let dist = scores.filter(\.hasDistribution)
        if !dist.isEmpty {
            b.distributionN = dist.count
            b.meanMixedEVLoss = meanCI(dist.compactMap(\.mixedEVLoss)).mean
            let mp = meanCI(dist.compactMap(\.mixedEVLossPot))
            b.meanMixedEVLossPot = mp.mean
            b.meanMixedEVLossPotCI = mp.ci
            let tvs = dist.compactMap(\.tvDistance)
            if !tvs.isEmpty {
                let tv = meanCI(tvs)
                b.meanTVDistance = tv.mean
                b.meanTVDistanceCI = tv.ci
            }
            b.meanBestActionProbability = meanCI(dist.compactMap(\.bestActionProbability)).mean
            let conf = dist.compactMap(\.confidence)
            if !conf.isEmpty { b.meanConfidence = meanCI(conf).mean }
        }
        return b
    }

    /// Per-decision scores for a run (only decisions it has answered).
    public static func scores(_ run: BenchmarkRun, suite: BenchmarkSuite) -> [(Decision, DecisionScore)] {
        let byId = Dictionary(run.results.map { ($0.decisionId, $0) }, uniquingKeysWith: { _, b in b })
        return suite.decisions.compactMap { d in
            guard let r = byId[d.id] else { return nil }
            return (d, score(d, result: r, run: run))
        }
    }

    public static func summarize(_ run: BenchmarkRun, suite: BenchmarkSuite) -> ModelScore {
        let pairs = scores(run, suite: suite)
        let ids = Set(pairs.map(\.0.id))
        let results = run.results.filter { ids.contains($0.decisionId) }
        var byStreet: [String: ScoreBucket] = [:]
        for (street, group) in Dictionary(grouping: pairs, by: { $0.0.street.rawValue }) {
            byStreet[street] = bucket(group.map(\.1))
        }
        var byType: [String: ScoreBucket] = [:]
        for (type, group) in Dictionary(grouping: pairs, by: { $0.0.decisionType.rawValue }) {
            byType[type] = bucket(group.map(\.1))
        }
        let latencies = results.map(\.latency)
        var row = ModelScore(id: run.id, model: run.model, label: run.label, kind: run.kind, answered: pairs.count,
                             total: suite.decisions.count, overall: bucket(pairs.map(\.1)), byStreet: byStreet, byType: byType,
                             meanLatency: latencies.isEmpty ? 0 : latencies.reduce(0, +) / Double(latencies.count),
                             totalCost: results.reduce(0) { $0 + $1.cost },
                             promptTokens: results.reduce(0) { $0 + $1.promptTokens },
                             completionTokens: results.reduce(0) { $0 + $1.completionTokens })
        row.variant = run.variantId
        if suite.isHands { row.perHand = handMetrics(pairs, suite: suite) }
        return row
    }

    /// Rows sorted by GTO score (desc), then EV loss (asc).
    public static func leaderboard(suite: BenchmarkSuite, runs: [BenchmarkRun]) -> [ModelScore] {
        runs.filter { $0.suiteId == suite.id }
            .map { summarize($0, suite: suite) }
            .filter { $0.answered > 0 }
            .sorted {
                if abs($0.overall.gtoScore - $1.overall.gtoScore) > 1e-9 { return $0.overall.gtoScore > $1.overall.gtoScore }
                return $0.overall.meanEVLossPot < $1.overall.meanEVLossPot
            }
    }
}

// MARK: - Per-hand metrics (hands suites)

/// Postflop **bb/100 lost vs GTO** for hands suites.
///
/// Definition. In a hands suite every decision of both players in a dealt hand is recorded, and
/// the benchmarked player answers all of them as the hero — i.e. it plays *both seats* of every
/// hand. For hand h let L_h = Σ_{decisions d in h} loss_d (bb; invalid answers lose the full EV
/// spread, as everywhere). Each hand therefore contains two seat-hands (the model in the OOP seat
/// and in the IP seat), and
///
///     bb/100 lost = 100 · mean_h(L_h / 2)
///
/// = expected big blinds lost per 100 hands *played in one seat*, averaged over both seats — the
/// unit a poker player would quote. The 95% CI treats hands as the sampling unit (decisions in a
/// hand are correlated, so they are clustered by hand): X_h = 100 · L_h / 2, normal approximation.
/// `mixed` uses Σ p(a)·loss(a) instead of the argmax loss (players with probabilities).
///
/// Caveat: losses are one-step deviations along the GTO-sampled line — each decision's loss
/// assumes GTO play continues afterwards, and the line does not branch on the model's choice. It
/// is the standard first-order EV-loss measure, not the result of a full match. Only hands whose
/// decisions were all answered are counted (`hands` ≤ suite hands for partial runs).
public struct HandMetrics: Codable, Hashable, Sendable {
    public var hands: Int
    public var bbPer100: Double
    public var bbPer100CI: Double
    public var mixedBbPer100: Double?
    public var mixedBbPer100CI: Double?
    /// Per-seat split (bb/100 lost in that seat, 100 · mean_h L_{h,seat}); "OOP" / "IP" (preflop suites: "SB" / "BB").
    public var bySeat: [String: Double]

    public init(hands: Int, bbPer100: Double, bbPer100CI: Double, mixedBbPer100: Double? = nil, mixedBbPer100CI: Double? = nil,
                bySeat: [String: Double] = [:]) {
        self.hands = hands
        self.bbPer100 = bbPer100
        self.bbPer100CI = bbPer100CI
        self.mixedBbPer100 = mixedBbPer100
        self.mixedBbPer100CI = mixedBbPer100CI
        self.bySeat = bySeat
    }
}

extension Scoring {
    /// Per-hand sums (bb) of argmax and mixed loss over completely answered hands, keyed by hand id.
    /// `mixed` is nil for hands containing a decision without distribution metrics.
    public static func handLosses(_ pairs: [(Decision, DecisionScore)], suite: BenchmarkSuite)
        -> [String: (loss: Double, mixed: Double?, seat: [Double])] {
        let perHand = Dictionary(grouping: suite.decisions.filter { $0.handId != nil }, by: { $0.handId! }).mapValues(\.count)
        var acc: [String: (loss: Double, mixed: Double?, seat: [Double], n: Int)] = [:]
        for (d, s) in pairs {
            guard let h = d.handId else { continue }
            var a = acc[h] ?? (0, 0, [0, 0], 0)
            a.loss += s.evLoss
            a.mixed = a.mixed.flatMap { m in s.mixedEVLoss.map { m + $0 } }
            a.seat[d.heroSeat] += s.evLoss
            a.n += 1
            acc[h] = a
        }
        return acc.filter { perHand[$0.key] == $0.value.n }.mapValues { ($0.loss, $0.mixed, $0.seat) }
    }

    public static func handMetrics(_ pairs: [(Decision, DecisionScore)], suite: BenchmarkSuite) -> HandMetrics? {
        let hands = handLosses(pairs, suite: suite)
        guard !hands.isEmpty else { return nil }
        let order = hands.keys.sorted()
        let x = meanCI(order.map { 100 * hands[$0]!.loss / 2 })
        var m = HandMetrics(hands: hands.count, bbPer100: x.mean, bbPer100CI: x.ci)
        let mixed = order.compactMap { hands[$0]!.mixed }
        if mixed.count == order.count {
            let mx = meanCI(mixed.map { 100 * $0 / 2 })
            m.mixedBbPer100 = mx.mean
            m.mixedBbPer100CI = mx.ci
        }
        let n = Double(hands.count)
        let seatNames = suite.mode == .preflop ? ["SB", "BB"] : ["OOP", "IP"]
        m.bySeat = [seatNames[0]: 100 * hands.values.reduce(0) { $0 + $1.seat[0] } / n,
                    seatNames[1]: 100 * hands.values.reduce(0) { $0 + $1.seat[1] } / n]
        return m
    }

    // MARK: Paired comparison

    /// Mean difference (a − b) with a 95% CI.
    public struct Diff: Codable, Hashable, Sendable {
        public var n: Int
        public var mean: Double
        public var ci: Double
        /// |mean| > ci.
        public var significant: Bool { n > 1 && abs(mean) > ci }
    }

    /// Paired difference between two runs on the decisions both answered: GTO score, EV loss % pot and
    /// mixed loss % pot are paired over decisions; bb/100 (hands suites) is paired over complete hands.
    public struct PairedComparison: Sendable {
        public var score: Diff
        public var lossPot: Diff
        public var mixedPot: Diff?
        public var bbPer100: Diff?
        public var mixedBbPer100: Diff?
    }

    public static func paired(_ a: BenchmarkRun, _ b: BenchmarkRun, suite: BenchmarkSuite) -> PairedComparison {
        let sa = Dictionary(scores(a, suite: suite).map { ($0.0.id, $0) }, uniquingKeysWith: { x, _ in x })
        let sb = Dictionary(scores(b, suite: suite).map { ($0.0.id, $0) }, uniquingKeysWith: { x, _ in x })
        let common = suite.decisions.map(\.id).filter { sa[$0] != nil && sb[$0] != nil }
        func diff(_ xs: [Double]) -> Diff { let m = meanCI(xs); return Diff(n: xs.count, mean: m.mean, ci: m.ci) }
        let score = diff(common.map { (sa[$0]!.1.score - sb[$0]!.1.score) * 100 })
        let loss = diff(common.map { sa[$0]!.1.evLossPot - sb[$0]!.1.evLossPot })
        let mixedIds = common.filter { sa[$0]!.1.mixedEVLossPot != nil && sb[$0]!.1.mixedEVLossPot != nil }
        var out = PairedComparison(score: score, lossPot: loss,
                                   mixedPot: mixedIds.isEmpty ? nil : diff(mixedIds.map { sa[$0]!.1.mixedEVLossPot! - sb[$0]!.1.mixedEVLossPot! }))
        if suite.isHands {
            let ha = handLosses(common.map { sa[$0]! }, suite: suite)
            let hb = handLosses(common.map { sb[$0]! }, suite: suite)
            let hands = ha.keys.filter { hb[$0] != nil }.sorted()
            if !hands.isEmpty {
                out.bbPer100 = diff(hands.map { 100 * (ha[$0]!.loss - hb[$0]!.loss) / 2 })
                let mh = hands.filter { ha[$0]!.mixed != nil && hb[$0]!.mixed != nil }
                if !mh.isEmpty { out.mixedBbPer100 = diff(mh.map { 100 * (ha[$0]!.mixed! - hb[$0]!.mixed!) / 2 }) }
            }
        }
        return out
    }
}
