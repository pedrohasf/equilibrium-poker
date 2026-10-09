import Foundation

/// One pairwise result between two rated players: `score` is player i's points out of `games`.
public struct PairwiseResult: Hashable, Sendable {
    public var i: Int
    public var j: Int
    /// Points for i (win = 1, tie = 0.5).
    public var score: Double
    public var games: Double

    public init(i: Int, j: Int, score: Double, games: Double) {
        self.i = i
        self.j = j
        self.score = score
        self.games = games
    }
}

/// Bradley–Terry strengths fitted with the MM algorithm, reported on the Elo scale.
public enum BradleyTerry {
    /// Returns Elo-style ratings (mean 1500). `prior` adds that many virtual drawn games
    /// against an average opponent, which keeps ratings finite for undefeated players.
    public static func fit(players n: Int, results: [PairwiseResult], prior: Double = 1, iterations: Int = 500) -> [Double] {
        guard n > 0 else { return [] }
        var p = [Double](repeating: 1, count: n)
        var wins = [Double](repeating: prior, count: n) // virtual draws: half of 2*prior games
        var pairs: [[Double]] = Array(repeating: Array(repeating: 0, count: n), count: n)
        for r in results where r.i != r.j && r.games > 0 {
            wins[r.i] += r.score
            wins[r.j] += r.games - r.score
            pairs[r.i][r.j] += r.games
            pairs[r.j][r.i] += r.games
        }
        for _ in 0..<iterations {
            var next = p
            var maxDelta = 0.0
            for i in 0..<n {
                // Virtual opponent of strength 1 with 2*prior games.
                var denom = 2 * prior / (p[i] + 1)
                for j in 0..<n where pairs[i][j] > 0 { denom += pairs[i][j] / (p[i] + p[j]) }
                next[i] = denom > 0 ? wins[i] / denom : p[i]
            }
            // Normalise to geometric mean 1.
            let g = exp(next.map { log(max($0, 1e-12)) }.reduce(0, +) / Double(n))
            for i in 0..<n {
                next[i] /= g
                maxDelta = max(maxDelta, abs(next[i] - p[i]))
            }
            p = next
            if maxDelta < 1e-10 { break }
        }
        return p.map { 1500 + 400 * log10(max($0, 1e-12)) }
    }

    /// Expected score of a player rated `a` vs `b`.
    public static func expected(_ a: Double, _ b: Double) -> Double { 1 / (1 + pow(10, (b - a) / 400)) }
}

public struct LeaderboardEntry: Hashable, Sendable, Identifiable {
    public var id: String
    public var spec: PlayerSpec
    public var rating: Double
    public var matches: Int
    public var hands: Int
    /// Duplicate units (pairs) played.
    public var units: Int
    public var netBB: Double
    public var bb100: Double
    public var ci95: Double?
    public var evBB100: Double
    public var evCI95: Double?
    /// Duplicate-pair outcomes against other players (counts; the rating weights them by size).
    public var wins: Int
    public var losses: Int
    public var ties: Int
    public var cost: Double
    public var invalidActions: Int
    public var decisions: Int
}

public enum Leaderboard {
    /// Aggregates all matches. Self-play matches are excluded from ratings and win rates.
    ///
    /// Rating: Bradley–Terry on the Elo scale where, for each match, player A's score out of
    /// `pairs` games is the share of big blinds A won over all duplicate pairs (sum of winning
    /// pair nets / sum of absolute pair nets). Expected score between two ratings is therefore
    /// the expected share of the money exchanged.
    public static func compute(_ matches: [MatchRecord]) -> [LeaderboardEntry] {
        var specs: [String: PlayerSpec] = [:]
        var units: [String: [ResultUnit]] = [:]
        var matchCount: [String: Int] = [:]
        var hands: [String: Int] = [:]
        var wins: [String: (Int, Int, Int)] = [:]
        var cost: [String: Double] = [:]
        var invalid: [String: Int] = [:]
        var decisions: [String: Int] = [:]
        var pairwise: [(String, String, Double, Double)] = []

        for m in matches where m.players.count == 2 && m.players[0].id != m.players[1].id && !m.hands.isEmpty {
            let u = (0..<2).map { MatchStats.units(m.hands, player: $0, duplicate: m.config.duplicate) }
            let summary = m.summary ?? MatchStats.summarize(m)
            for p in 0..<2 {
                let id = m.players[p].id
                specs[id] = m.players[p]
                units[id, default: []] += u[p]
                matchCount[id, default: 0] += 1
                hands[id, default: 0] += m.hands.count
                cost[id, default: 0] += summary.players[p].cost
                invalid[id, default: 0] += summary.players[p].invalidActions
                decisions[id, default: 0] += summary.players[p].decisions
            }
            // Score = share of the big blinds that changed hands across duplicate pairs, so a pair won by
            // 100 bb counts more than a pair lost by 1 bb (pure win/loss counts reward nits).
            var won = 0.0, lost = 0.0
            var w = 0, l = 0, t = 0
            for x in u[0] {
                if x.net > 1e-9 { won += x.net; w += 1 } else if x.net < -1e-9 { lost -= x.net; l += 1 } else { t += 1 }
            }
            let share = won + lost > 0 ? won / (won + lost) : 0.5
            let score = share * Double(u[0].count)
            let a = m.players[0].id, b = m.players[1].id
            wins[a] = (wins[a, default: (0, 0, 0)].0 + w, wins[a, default: (0, 0, 0)].1 + l, wins[a, default: (0, 0, 0)].2 + t)
            wins[b] = (wins[b, default: (0, 0, 0)].0 + l, wins[b, default: (0, 0, 0)].1 + w, wins[b, default: (0, 0, 0)].2 + t)
            if !u[0].isEmpty { pairwise.append((a, b, score, Double(u[0].count))) }
        }

        let ids = specs.keys.sorted()
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let ratings = BradleyTerry.fit(players: ids.count, results: pairwise.map {
            PairwiseResult(i: index[$0.0]!, j: index[$0.1]!, score: $0.2, games: $0.3)
        })

        return ids.enumerated().map { k, id in
            let r = MatchStats.rate(units[id] ?? [])
            let (w, l, t) = wins[id] ?? (0, 0, 0)
            let us = units[id] ?? []
            return LeaderboardEntry(id: id, spec: specs[id]!, rating: ratings[k], matches: matchCount[id] ?? 0, hands: hands[id] ?? 0,
                                    units: us.count, netBB: us.reduce(0) { $0 + $1.net }, bb100: r.bb100, ci95: r.ci95,
                                    evBB100: r.evBB100, evCI95: r.evCI95, wins: w, losses: l, ties: t, cost: cost[id] ?? 0,
                                    invalidActions: invalid[id] ?? 0, decisions: decisions[id] ?? 0)
        }
        .sorted { $0.rating > $1.rating }
    }
}
