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
    /// 1 − loss / (best − worst), in [0, 1]. Decisions where every action has the same EV score 1.
    public var score: Double
    /// Within `Scoring.bestTolerance` of the best EV.
    public var isBest: Bool
    /// Chosen action is played at least `Scoring.approvedFrequency` of the time by GTO with this hand.
    public var approved: Bool
    /// EV loss above `Scoring.blunderThreshold` of the pot.
    public var blunder: Bool
    /// GTO frequency of the chosen action (0 if invalid).
    public var gtoFrequency: Double
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
    public var reasoningTokens: Int

    public var isComplete: Bool { answered >= total }
    public var totalTokens: Int { promptTokens + completionTokens }
    public var isBaseline: Bool { kind == .baseline }
}

public enum Scoring {
    /// An answer counts as "best" when within this fraction of the pot of the top EV
    /// (solutions are only converged to ~0.3–0.5% pot, so exact ties are meaningless).
    public static let bestTolerance = 0.0025
    public static let approvedFrequency = 0.10
    public static let blunderThreshold = 0.25

    public static func score(_ d: Decision, choice: Int?) -> DecisionScore {
        let valid = choice.map { d.actions.indices.contains($0) } ?? false
        let c = valid ? choice : nil
        let loss = d.evLoss(c)
        let pot = max(d.pot, 1e-9)
        let spread = d.evSpread
        let s = spread > 1e-9 ? max(0, min(1, 1 - loss / spread)) : 1
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
        return ScoreBucket(n: scores.count, meanEVLoss: loss.mean, meanEVLossCI: loss.ci, meanEVLossPot: lossPot.mean,
                           meanEVLossPotCI: lossPot.ci, gtoScore: gto.mean, gtoScoreCI: gto.ci, accuracy: rate(\.isBest),
                           approvedRate: rate(\.approved), blunderRate: rate(\.blunder), invalidRate: rate { !$0.valid })
    }

    /// Per-decision scores for a run (only decisions it has answered).
    public static func scores(_ run: BenchmarkRun, suite: BenchmarkSuite) -> [(Decision, DecisionScore)] {
        let byId = Dictionary(run.results.map { ($0.decisionId, $0) }, uniquingKeysWith: { _, b in b })
        return suite.decisions.compactMap { d in
            guard let r = byId[d.id] else { return nil }
            return (d, score(d, choice: r.choice))
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
        return ModelScore(id: run.id, model: run.model, label: run.label, kind: run.kind, answered: pairs.count,
                          total: suite.decisions.count, overall: bucket(pairs.map(\.1)), byStreet: byStreet, byType: byType,
                          meanLatency: latencies.isEmpty ? 0 : latencies.reduce(0, +) / Double(latencies.count),
                          totalCost: results.reduce(0) { $0 + $1.cost },
                          promptTokens: results.reduce(0) { $0 + $1.promptTokens },
                          completionTokens: results.reduce(0) { $0 + $1.completionTokens },
                          reasoningTokens: results.reduce(0) { $0 + $1.reasoningTokens })
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
