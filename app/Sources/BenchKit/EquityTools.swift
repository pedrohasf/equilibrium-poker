import Foundation
import SolverKit

/// Information a real bot could compute from the public state plus its own cards — never solver
/// data. Used by the `eq` / `eqrange` state variants and the guardrail post-hoc player.
///
/// * Hero equity vs the villain's **preflop** range: Monte-Carlo (`GTOCore.equity`, deterministic
///   seed derived from the cards, 5 000 samples).
/// * Made-hand percentile: share of the villain's (weighted) range that hero's current best hand
///   beats on the current board (ties count ½). Draws are ignored, it is "showdown now".
/// * Narrowed range (`narrowedWeights`): the villain's preflop range re-weighted by the villain's
///   actions so far with a simple strength heuristic (see there).
public enum EquityTools {
    public static let samples = 5_000

    /// All 1326 combos in solver index order.
    public static let allCombos: [Combo] = {
        var out = [Combo?](repeating: nil, count: 1326)
        for hi in 1..<52 {
            for lo in 0..<hi {
                let c = Combo(Card(index: hi), Card(index: lo))
                out[c.index] = c
            }
        }
        return out.map { $0! }
    }()

    /// The villain's preflop range text from the decision's scenario (nil for unknown scenarios).
    public static func villainRangeText(_ d: Decision) -> String? {
        guard let s = Scenarios.named(d.scenarioId) else { return nil }
        return d.heroSeat == 0 ? s.rangeIP : s.rangeOOP
    }

    /// Preflop weights (1326, combo index order) with combos blocked by `dead` removed.
    static func preflopWeights(_ d: Decision, dead: [Card]) -> [Double]? {
        guard let text = villainRangeText(d), let w = try? GTOCore.parseRange(text) else { return nil }
        let deadSet = Set(dead)
        return allCombos.map { c in deadSet.contains(c.high) || deadSet.contains(c.low) ? 0 : Double(w[c.index]) }
    }

    /// Facts derived for one decision (cached; computing them costs a few ms).
    public struct Facts: Sendable, Hashable {
        /// Hero equity vs the villain's preflop range (0–1).
        public var equityPreflop: Double
        /// Hero equity vs the heuristically narrowed range (0–1).
        public var equityNarrowed: Double
        /// Share of the preflop range hero's made hand beats now (0–1).
        public var percentilePreflop: Double
        /// Share of the narrowed range hero's made hand beats now (0–1).
        public var percentileNarrowed: Double
        /// Effective number of combos left in the narrowed range vs the preflop range (board-filtered).
        public var narrowedCombos: Double
        public var preflopCombos: Double
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Facts] = [:]

    static func cacheKey(_ d: Decision) -> String {
        let h = d.history.map { e in "\(e.street.rawValue)\(e.seat ?? -1)\(e.action?.label ?? e.card ?? "")" }.joined(separator: ",")
        return "\(d.scenarioId)|\(d.heroSeat)|\(d.heroCards)|\(d.board.joined())|\(h)"
    }

    /// Facts for a decision, or nil if the scenario's ranges are unknown or the evaluator fails.
    public static func facts(_ d: Decision) -> Facts? {
        let key = cacheKey(d)
        if let f = lock.withLock({ cache[key] }) { return f }
        guard let f = compute(d) else { return nil }
        lock.withLock { cache[key] = f }
        return f
    }

    static func compute(_ d: Decision) -> Facts? {
        if d.street == .preflop { return computePreflop(d) }
        let hero = d.heroCardList, board = d.boardCards
        guard hero.count == 2, board.count >= 3, let pre = preflopWeights(d, dead: hero + board),
              let preText = villainRangeText(d) else { return nil }
        let narrowed = narrowedWeights(d, preflop: pre)
        guard let eqPre = try? GTOCore.equity(hand: hero, board: board, range: preText, samples: samples) else { return nil }
        let eqNar = (try? GTOCore.equity(hand: hero, board: board, range: rangeText(narrowed), samples: samples)) ?? eqPre
        let (pctPre, pctNar) = (percentile(hero: hero, board: board, weights: pre) ?? 0.5,
                                percentile(hero: hero, board: board, weights: narrowed) ?? 0.5)
        return Facts(equityPreflop: eqPre, equityNarrowed: eqNar, percentilePreflop: pctPre, percentileNarrowed: pctNar,
                     narrowedCombos: narrowed.reduce(0, +), preflopCombos: pre.reduce(0, +))
    }

    /// Weighted combo list in range syntax ("AsKd:0.35,…"); weights are scaled so the maximum is 1.
    static func rangeText(_ w: [Double]) -> String {
        let mx = w.max() ?? 0
        guard mx > 0 else { return "" }
        return w.indices.filter { w[$0] > 1e-6 }.map { i in
            let c = allCombos[i]
            return "\(c.high)\(c.low):\(String(format: "%.4f", w[i] / mx))"
        }.joined(separator: ",")
    }

    /// Made-hand values for each combo with positive weight on `board` (nil entries = weight 0).
    static func values(_ w: [Double], board: [Card]) -> [UInt32?]? {
        let idx = w.indices.filter { w[$0] > 0 }
        guard let vals = try? GTOCore.evaluate(idx.map { allCombos[$0].cards + board }) else { return nil }
        var out = [UInt32?](repeating: nil, count: w.count)
        for (k, i) in idx.enumerated() { out[i] = vals[k].value }
        return out
    }

    /// Share of the weighted range that hero's made hand beats on `board` (ties ½).
    static func percentile(hero: [Card], board: [Card], weights w: [Double]) -> Double? {
        guard let hv = (try? GTOCore.evaluate([hero + board]))?.first?.value, let vals = values(w, board: board) else { return nil }
        var beat = 0.0, total = 0.0
        for i in w.indices {
            guard let v = vals[i], w[i] > 0 else { continue }
            total += w[i]
            beat += hv > v ? w[i] : hv == v ? w[i] / 2 : 0
        }
        return total > 0 ? beat / total : nil
    }

    /// Flush draw or open-ended straight draw (no made flush/straight) on a flop or turn board.
    static func hasStrongDraw(_ hole: [Card], board: [Card]) -> Bool {
        guard board.count < 5 else { return false }
        let all = hole + board
        for s in Set(hole.map(\.suit)) where all.filter({ $0.suit == s }).count == 4 { return true }
        func straight(_ ranks: Set<Int>) -> Bool {
            var rs = ranks
            if rs.contains(12) { rs.insert(-1) }
            return (-1...8).contains { lo in (lo...(lo + 4)).allSatisfy(rs.contains) }
        }
        let have = Set(all.map { $0.rank.rawValue })
        if straight(have) { return false }
        let outs = (0..<13).filter { !have.contains($0) && straight(have.union([$0])) }
        return outs.count >= 2
    }

    /// Fraction of the villain's range kept "for value" after an aggressive action of `sizePot` × pot.
    public static func valueFraction(sizePot f: Double, isRaise: Bool) -> Double {
        let base: Double = f <= 0.4 ? 0.5 : f <= 0.8 ? 0.4 : f <= 1.5 ? 0.3 : 0.2
        return isRaise ? base / 2 : base
    }

    /// Per-combo weight of non-value, non-draw hands after a bet of `f` × pot, chosen so that bluffs make up
    /// the balanced share β = f / (1 + 2f) of the betting range on the river (value fraction ν at weight 1:
    /// b = βν / ((1 − β)(1 − ν))). Before the river draws carry most bluffs, so pure air gets half that.
    public static func bluffWeight(sizePot f: Double, valueFraction v: Double, river: Bool) -> Double {
        let beta = max(0, f) / (1 + 2 * max(0, f))
        let b = beta * v / max(1e-9, (1 - beta) * (1 - v))
        return min(1, river ? b : b / 2)
    }

    /// The villain's preflop range narrowed by the villain's own actions, street by street.
    ///
    /// Heuristic (no solver data): for each villain action, combos are ranked by made-hand strength
    /// on that street's board (weighted percentile q within the current range) and re-weighted:
    /// * bet / raise / all-in of size f × pot: the top `valueFraction(f)` keep weight 1 (raises: half
    ///   as many), flush / open-ended draws (flop, turn) 0.7 (semi-bluffs), everything else
    ///   `bluffWeight(f)` (river: the balanced bluff share f/(1+2f) of the betting range; earlier: half);
    /// * call: the bottom 30% drop to 0.15 unless they hold a strong draw (0.8);
    /// * check: the top 15% drop to 0.5 (strong hands usually bet, but sometimes trap).
    public static func narrowedWeights(_ d: Decision, preflop: [Double]) -> [Double] {
        var w = preflop
        let villain = 1 - d.heroSeat
        let board = d.boardCards
        for (idx, e) in d.history.enumerated() where e.seat == villain {
            guard let a = e.action else { continue }
            // A raise (or all-in over a bet): the hero was aggressive earlier on this street.
            let facing = d.history[..<idx].contains { $0.street == e.street && $0.seat == d.heroSeat && ($0.action?.kind.isAggressive ?? false) }
            let b = Array(board.prefix(e.street.boardCount))
            guard b.count >= 3, let vals = values(w, board: b) else { continue }
            // Weighted strength percentile (ties at the midpoint).
            let live = w.indices.filter { w[$0] > 0 && vals[$0] != nil }.sorted { vals[$0]! < vals[$1]! }
            let total = live.reduce(0) { $0 + w[$1] }
            guard total > 0 else { continue }
            var q = [Double](repeating: 0, count: w.count)
            var k = 0, below = 0.0
            while k < live.count {
                var j = k, tie = 0.0
                while j < live.count && vals[live[j]] == vals[live[k]] { tie += w[live[j]]; j += 1 }
                for t in k..<j { q[live[t]] = (below + tie / 2) / total }
                below += tie
                k = j
            }
            for i in live {
                let draw = hasStrongDraw(allCombos[i].cards, board: b)
                switch a.kind {
                case .bet, .raise, .allin:
                    let f = a.kind == .allin ? a.amount / max(e.potBefore, 1e-9) : a.potFraction
                    let v = valueFraction(sizePot: f, isRaise: a.kind == .raise || (a.kind == .allin && facing))
                    w[i] *= q[i] >= 1 - v ? 1 : draw ? 0.7 : bluffWeight(sizePot: f, valueFraction: v, river: b.count == 5)
                case .call:
                    if q[i] < 0.3 { w[i] *= draw ? 0.8 : 0.15 }
                case .check:
                    if q[i] > 0.85 { w[i] *= 0.5 }
                case .fold:
                    break
                }
            }
        }
        return w
    }

    // MARK: Preflop (no board)

    /// Every two-card hand.
    public static let anyTwo = "22+,A2s+,K2s+,Q2s+,J2s+,T2s+,92s+,82s+,72s+,62s+,52s+,42s+,32s,A2o+,K2o+,Q2o+,J2o+,T2o+,92o+,82o+,72o+,62o+,52o+,42o+,32o"

    /// Preflop strength of each combo (1326, combo index order): its hand class's all-in equity vs a random
    /// hand (Monte-Carlo, 4 000 samples per class, computed once).
    public static let preflopStrength: [Double] = {
        var byClass: [String: Double] = [:]
        return allCombos.map { c in
            let code = DecisionStateBuilder.handClassCode(c.cards)
            if let v = byClass[code] { return v }
            let v = (try? GTOCore.equity(hand: c.cards, board: [], range: anyTwo, samples: 4_000)) ?? 0.5
            byClass[code] = v
            return v
        }
    }()

    /// Weighted percentile (0 = weakest, 1 = strongest) of every live combo by `preflopStrength`.
    static func preflopPercentiles(_ w: [Double]) -> [Double] {
        let live = w.indices.filter { w[$0] > 0 }.sorted { preflopStrength[$0] < preflopStrength[$1] }
        let total = live.reduce(0) { $0 + w[$1] }
        var q = [Double](repeating: 0, count: w.count)
        var below = 0.0
        for i in live {
            q[i] = total > 0 ? (below + w[i] / 2) / total : 0
            below += w[i]
        }
        return q
    }

    /// The villain's plausible preflop range given its actions (heuristic, no solver data). Starting from every
    /// hand (card removal applied), for each villain action with r raises before it on the street:
    /// * first raise (open / iso): top 60% keep weight 1, the rest 0.1; 3-bet (r = 1): top 18%; 4-bet+: top 8%;
    /// * all-in: first-in top min(70%, 8 / stack) (push/fold-like); facing a raise top min(40%, 4 / stack), floor 8%;
    /// * call: facing an open keep the top 70% (weakest 30% → 0.1, the top 5% → 0.6 since they usually re-raise);
    ///   facing a 3-bet top 30%; facing a 4-bet+ top 12%;
    /// * limp (SB completes): bottom 15% → 0.2, top 10% → 0.5; check (BB after a limp): top 20% → 0.3.
    public static func preflopNarrowedWeights(_ d: Decision, start: [Double]) -> [Double] {
        var w = start
        let villain = 1 - d.heroSeat
        let stack = max(1, d.stacks.max() ?? 100) + (d.history.compactMap { $0.action?.to }.max() ?? 0)
        var raises = 0
        for e in d.history {
            guard let a = e.action, let seat = e.seat else { continue }
            if seat == villain {
                let q = preflopPercentiles(w)
                func keepTop(_ f: Double, rest: Double = 0.1) { for i in w.indices where w[i] > 0 && q[i] < 1 - f { w[i] *= rest } }
                switch a.kind {
                case .raise, .bet: keepTop(raises == 0 ? 0.6 : raises == 1 ? 0.18 : 0.08)
                case .allin:
                    keepTop(raises == 0 ? min(0.7, 8 / stack) : max(0.08, min(0.4, 4 / stack)))
                case .call:
                    if a.name?.hasPrefix("Limp") == true {
                        for i in w.indices where w[i] > 0 { w[i] *= q[i] < 0.15 ? 0.2 : q[i] > 0.9 ? 0.5 : 1 }
                    } else {
                        let f = raises <= 1 ? 0.7 : raises == 2 ? 0.3 : 0.12
                        for i in w.indices where w[i] > 0 { w[i] *= q[i] < 1 - f ? 0.1 : (raises <= 1 && q[i] > 0.95) ? 0.6 : 1 }
                    }
                case .check:
                    for i in w.indices where w[i] > 0 && q[i] > 0.8 { w[i] *= 0.3 }
                case .fold:
                    break
                }
            }
            if a.kind == .raise || a.kind == .bet || a.kind == .allin { raises += 1 }
        }
        return w
    }

    static func computePreflop(_ d: Decision) -> Facts? {
        let hero = d.heroCardList
        guard hero.count == 2 else { return nil }
        let start = allCombos.map { c in hero.contains(c.high) || hero.contains(c.low) ? 0.0 : 1.0 }
        let narrowed = preflopNarrowedWeights(d, start: start)
        guard let eqAny = try? GTOCore.equity(hand: hero, board: [], range: anyTwo, samples: samples) else { return nil }
        let eqNar = (try? GTOCore.equity(hand: hero, board: [], range: rangeText(narrowed), samples: samples)) ?? eqAny
        let mine = preflopStrength[Combo(hero[0], hero[1]).index]
        func pct(_ w: [Double]) -> Double {
            var beat = 0.0, total = 0.0
            for i in w.indices where w[i] > 0 {
                total += w[i]
                beat += mine > preflopStrength[i] + 1e-9 ? w[i] : abs(mine - preflopStrength[i]) <= 1e-9 ? w[i] / 2 : 0
            }
            return total > 0 ? beat / total : 0.5
        }
        return Facts(equityPreflop: eqAny, equityNarrowed: eqNar, percentilePreflop: pct(start), percentileNarrowed: pct(narrowed),
                     narrowedCombos: narrowed.reduce(0, +), preflopCombos: start.reduce(0, +))
    }
}
