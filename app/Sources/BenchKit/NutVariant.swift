import Foundation
import OpenRouterKit
import SolverKit

/// Exact "how close to the nuts" facts: of every two-card holding the villain could have
/// (all combos not blocked by the board or hero's cards), how many beat or tie hero right now.
/// Pure card arithmetic — no solver data.
public enum NutFacts {
    public struct Facts: Sendable, Hashable {
        public var beatenBy: Int
        public var ties: Int
        public var total: Int
        public var category: String
        /// Distinct hand ranks that beat hero (1 = only one better hand type).
        public var betterClasses: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Facts] = [:]

    public static func facts(_ d: Decision) -> Facts? {
        let hero = d.heroCardList, board = d.boardCards
        guard hero.count == 2, board.count >= 3 else { return nil }
        let key = hero.compactText + board.compactText
        if let f = lock.withLock({ cache[key] }) { return f }
        let dead = Set(hero + board)
        let opps = Combo.all.filter { !dead.contains($0.high) && !dead.contains($0.low) }
        guard let values = try? GTOCore.evaluate([hero + board] + opps.map { $0.cards + board }), let h = values.first else { return nil }
        let others = values.dropFirst()
        let better = others.filter { $0 > h }
        let f = Facts(beatenBy: better.count, ties: others.filter { $0.value == h.value }.count, total: opps.count,
                      category: h.category, betterClasses: Set(better.map(\.value)).count)
        lock.withLock { cache[key] = f }
        return f
    }

    public static func describe(_ f: Facts) -> String {
        if f.beatenBy == 0 {
            return f.ties > 0 ? "hero holds the nuts (can only be tied, never beaten, right now)" : "hero holds the absolute nuts right now"
        }
        let pct = 100.0 * Double(f.beatenBy) / Double(max(1, f.total))
        let near = f.betterClasses <= 2 && pct < 3 ? " — a near-nut hand" : ""
        return "\(f.beatenBy) of \(f.total) possible villain holdings (\(String(format: "%.1f", pct))%) beat hero right now\(near)"
    }
}

extension DecisionVariants {
    static let nutInstructions = B.instructions
        + " Hand strength matters most in big pots: with the nuts or a near-nut hand on the river, choose the action that extracts the most chips"
        + " (usually a bet or raise, including large sizes); on earlier streets with a very strong hand, just calling can be right when it keeps"
        + " the villain's bluffs and weaker hands in, especially on dry or paired boards where the villain has few hands that can continue."

    /// eqrange + exact nut-ranking facts (how many villain holdings beat hero now) + value-extraction guidance.
    public static let nuts = DecisionVariant(
        id: "nuts", summary: "eqrange + exact nut ranking (holdings that beat hero now) + value-extraction guidance for strong hands",
        build: { d in
            let f = EquityTools.facts(d)
            var state = withEquity(B.state(d), d, f, narrowed: true)
            if let n = NutFacts.facts(d), case .object(var root) = state, case .object(var hero)? = root["hero"] {
                hero["nut_ranking"] = .string(NutFacts.describe(n))
                hero["holdings_that_beat_hero_now"] = .number(Double(n.beatenBy))
                hero["is_the_nuts_now"] = .bool(n.beatenBy == 0)
                root["hero"] = .object(hero)
                state = .object(root)
            }
            return (state, [B.questionId: .choice(instructions: nutInstructions, criteria: equityCriteria(d, f, narrowed: true))])
        },
        interpret: { r, d in singleChoice(r, d) })
}

extension DecisionVariants {
    static let shortStackInstructions = B.instructions
        + " Stack depth changes preflop strategy: with 25 big blinds or less, a small raise that commits a large part of the stack"
        + " is rarely best — the strong options are usually to limp or call (to see a cheap flop with playable hands), to fold, or to go all-in"
        + " (which wins the blinds and antes immediately when the villain folds and denies them the chance to outplay you). Facing an all-in,"
        + " call when the hero's hand is strong enough against the villain's shoving range given the price."

    /// v2 + stack-depth guidance for short-stacked preflop play (limp/call, fold or shove; avoid small raises).
    public static let shortstack = DecisionVariant(
        id: "shortstack", summary: "v2 + short-stack preflop guidance (≤25bb: limp/call, fold or shove; small raises rarely best)",
        build: { d in
            let qs = B.questions(d)
            guard d.street == .preflop, d.stacks.min() ?? 100 <= 30, case .choice(_, let criteria)? = qs[B.questionId] else { return (B.state(d), qs) }
            return (B.state(d), [B.questionId: .choice(instructions: shortStackInstructions, criteria: criteria)])
        },
        interpret: { r, d in singleChoice(r, d) })
}
