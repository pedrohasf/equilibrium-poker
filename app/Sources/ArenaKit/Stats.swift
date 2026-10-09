import Foundation

/// Per-player results and tendencies for one match.
public struct PlayerSummary: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var hands: Int
    public var netBB: Double
    /// Win rate from complete duplicate units (pairs) — see `MatchStats.units`.
    public var bb100: Double
    /// Half-width of the 95% confidence interval of `bb100` (nil with fewer than 2 units).
    public var ci95: Double?
    public var evNetBB: Double
    public var evBB100: Double
    public var evCI95: Double?

    /// Voluntarily put money in pot preflop (calls or raises; blinds don't count).
    public var vpip: Double?
    /// Raised preflop.
    public var pfr: Double?
    /// Re-raised when facing a single raise preflop.
    public var threeBet: Double?
    /// Postflop (bets + raises) / calls.
    public var aggression: Double?
    /// Went to showdown when the flop was seen.
    public var wtsd: Double?
    /// Won money at showdown (splits count half).
    public var wsd: Double?
    /// As preflop aggressor, bet the flop when first given the chance.
    public var cbet: Double?
    /// Folded to a flop continuation bet.
    public var foldToCbet: Double?

    public var decisions: Int
    /// Decisions replaced by the check/fold default (unparseable / failed / illegal).
    public var invalidActions: Int
    /// Parse failures and API errors (including ones recovered by the retry).
    public var errors: Int
    public var cost: Double
    public var avgLatency: Double?
    public var promptTokens: Int
    public var completionTokens: Int
}

public struct MatchSummary: Codable, Hashable, Sendable {
    public var hands: Int
    /// Complete units used for bb/100 (duplicate pairs, or single hands).
    public var units: Int
    /// Player A, player B.
    public var players: [PlayerSummary]
}

/// One variance-reduction unit: both replicas of a deal (or a single hand when not duplicate).
public struct ResultUnit: Hashable, Sendable {
    public var deal: Int
    public var hands: Int
    /// Net big blinds for the player over the unit.
    public var net: Double
    public var evNet: Double
}

public struct RateEstimate: Hashable, Sendable {
    public var bb100: Double
    public var ci95: Double?
    public var evBB100: Double
    public var evCI95: Double?
}

public enum MatchStats {
    /// Complete units for `player` (0 = A, 1 = B). In duplicate mode only deals with both replicas count.
    public static func units(_ hands: [HandRecord], player: Int, duplicate: Bool) -> [ResultUnit] {
        let groups = Dictionary(grouping: hands, by: \.deal)
        return groups.keys.sorted().compactMap { d in
            let hs = groups[d]!
            if duplicate && Set(hs.map(\.replica)).count < 2 { return nil }
            return ResultUnit(deal: d, hands: hs.count, net: hs.reduce(0) { $0 + $1.net(player) },
                              evNet: hs.reduce(0) { $0 + $1.evNet(player) })
        }
    }

    /// bb/100 and 95% CI from per-unit win rates.
    public static func rate(_ units: [ResultUnit]) -> RateEstimate {
        let totalHands = units.reduce(0) { $0 + $1.hands }
        guard totalHands > 0 else { return RateEstimate(bb100: 0, ci95: nil, evBB100: 0, evCI95: nil) }
        func estimate(_ value: (ResultUnit) -> Double) -> (Double, Double?) {
            let mean = units.reduce(0) { $0 + value($1) } / Double(totalHands) * 100
            guard units.count >= 2 else { return (mean, nil) }
            let rates = units.map { value($0) / Double($0.hands) * 100 }
            let m = rates.reduce(0, +) / Double(rates.count)
            let variance = rates.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(rates.count - 1)
            return (mean, 1.96 * (variance / Double(rates.count)).squareRoot())
        }
        let (r, ci) = estimate(\.net)
        let (e, eci) = estimate(\.evNet)
        return RateEstimate(bb100: r, ci95: ci, evBB100: e, evCI95: eci)
    }

    public static func summarize(_ m: MatchRecord) -> MatchSummary {
        let players = (0..<2).map { player(m.hands, player: $0, spec: m.players[$0], duplicate: m.config.duplicate) }
        return MatchSummary(hands: m.hands.count, units: units(m.hands, player: 0, duplicate: m.config.duplicate).count, players: players)
    }

    struct Counter {
        var n = 0, d = 0.0
        mutating func add(_ hit: Bool) { n += 1; d += hit ? 1 : 0 }
        mutating func add(_ v: Double) { n += 1; d += v }
        var value: Double? { n > 0 ? d / Double(n) : nil }
    }

    public static func player(_ hands: [HandRecord], player p: Int, spec: PlayerSpec, duplicate: Bool) -> PlayerSummary {
        var vpip = Counter(), pfr = Counter(), threeBet = Counter(), wtsd = Counter(), wsd = Counter(), cbet = Counter(), foldCbet = Counter()
        var aggr = 0, calls = 0, decisions = 0, invalid = 0, errors = 0, ptok = 0, ctok = 0
        var cost = 0.0, latency = 0.0, timed = 0
        var net = 0.0, ev = 0.0

        for h in hands {
            let s = h.seat(of: p), o = 1 - s
            net += h.net(p)
            ev += h.evNet(p)
            let pre = h.actions.filter { $0.street == .preflop }
            let mine = h.actions.filter { $0.seat == s }
            vpip.add(pre.contains { $0.seat == s && ($0.kind == .call || $0.kind == .raise || $0.kind == .bet) })
            pfr.add(pre.contains { $0.seat == s && $0.kind == .raise })

            var raises = 0
            var lastRaiser: Int?
            for a in pre {
                if a.seat == s && raises == 1 && lastRaiser == o {
                    threeBet.add(a.kind == .raise)
                    break
                }
                if a.kind == .raise { raises += 1; lastRaiser = a.seat }
            }

            let sawFlop = !pre.contains { $0.kind == .fold }
            if sawFlop {
                wtsd.add(h.result.showdown)
            }
            if h.result.showdown {
                let n = h.result.net[s]
                wsd.add(n > 0 ? 1.0 : (n == 0 ? 0.5 : 0.0))
            }

            for a in mine where a.street != .preflop {
                if a.kind == .bet || a.kind == .raise { aggr += 1 }
                if a.kind == .call { calls += 1 }
            }

            // Continuation bets.
            let pfa = pre.last { $0.kind == .raise }?.seat
            let flop = h.actions.filter { $0.street == .flop }
            if let pfa, let i = flop.firstIndex(where: { $0.seat == pfa }), !flop[..<i].contains(where: { $0.kind == .bet }) {
                if pfa == s { cbet.add(flop[i].kind == .bet) }
                if flop[i].kind == .bet, pfa == o, let reply = flop[(i + 1)...].first(where: { $0.seat == s }) {
                    foldCbet.add(reply.kind == .fold)
                }
            }

            for a in mine {
                decisions += 1
                guard let m = a.meta else { continue }
                if m.fallback { invalid += 1 }
                errors += m.errors
                cost += m.cost
                ptok += m.promptTokens
                ctok += m.completionTokens
                if m.latency > 0 { latency += m.latency; timed += 1 }
            }
        }

        let r = rate(units(hands, player: p, duplicate: duplicate))
        return PlayerSummary(id: spec.id, name: spec.displayName, hands: hands.count, netBB: net, bb100: r.bb100, ci95: r.ci95,
                             evNetBB: ev, evBB100: r.evBB100, evCI95: r.evCI95,
                             vpip: vpip.value, pfr: pfr.value, threeBet: threeBet.value,
                             aggression: calls > 0 ? Double(aggr) / Double(calls) : (aggr > 0 ? Double(aggr) : nil),
                             wtsd: wtsd.value, wsd: wsd.value, cbet: cbet.value, foldToCbet: foldCbet.value,
                             decisions: decisions, invalidActions: invalid, errors: errors, cost: cost,
                             avgLatency: timed > 0 ? latency / Double(timed) : nil, promptTokens: ptok, completionTokens: ctok)
    }

    /// Short text for decision-model states: opponent tendencies and own result so far.
    public static func promptSummary(_ hands: [HandRecord], me: Int, specs: [PlayerSpec]) -> String? {
        guard hands.count >= 5 else { return nil }
        let opp = player(hands, player: 1 - me, spec: specs[1 - me], duplicate: false)
        let mine = hands.reduce(0) { $0 + $1.net(me) }
        func pct(_ x: Double?) -> String { x.map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a" }
        let af = opp.aggression.map { String(format: "%.1f", $0) } ?? "n/a"
        return """
        \(hands.count) hands completed. Your net result: \(String(format: "%+.1f", mine)) bb.
        Opponent tendencies: VPIP \(pct(opp.vpip)), PFR \(pct(opp.pfr)), 3-bet \(pct(opp.threeBet)), postflop aggression factor \(af), \
        c-bet \(pct(opp.cbet)), fold to c-bet \(pct(opp.foldToCbet)), went to showdown \(pct(opp.wtsd)).
        """
    }
}
