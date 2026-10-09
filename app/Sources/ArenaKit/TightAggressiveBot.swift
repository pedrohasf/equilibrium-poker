import Foundation
import SolverKit

/// A solid but exploitable baseline: preflop charts from `RangeLibrary`, postflop
/// Monte-Carlo equity vs. a range inferred from the opponent's preflop line.
public struct TightAggressiveBot: ArenaPlayer {
    public init() {}
    public var name: String { "TAG bot" }

    static let anyTwo = "22+,A2s+,K2s+,Q2s+,J2s+,T2s+,92s+,82s+,72s+,62s+,52s+,42s+,32s,A2o+,K2o+,Q2o+,J2o+,T2o+,92o+,82o+,72o+,62o+,52o+,42o+,32o"
    static let premium = "QQ+,AKs,AKo"
    static let strong = "TT+,AQs+,AKo"
    static let fourBetCall = "JJ+,AQs+,AKo"

    private static let parsed: [String: [Float]] = {
        var d: [String: [Float]] = [:]
        for r in [RangeLibrary.sbOpen, RangeLibrary.bbCallVsSb, RangeLibrary.bb3betVsBtn, RangeLibrary.btnCallVs3bet,
                  anyTwo, premium, strong, fourBetCall] {
            d[r] = (try? GTOCore.parseRange(r)) ?? Array(repeating: 0, count: 1326)
        }
        return d
    }()

    static func weight(_ range: String, _ hole: [Card]) -> Double {
        let idx = Combo(hole[0], hole[1]).index
        if let w = parsed[range] { return Double(w[idx]) }
        return Double((try? GTOCore.parseRange(range))?[idx] ?? 0)
    }

    public func decide(_ ctx: DecisionContext) async throws -> Decision {
        var rng = SeededRNG(seed: ctx.rngSeed)
        if ctx.state.street == .preflop { return preflop(ctx, &rng) }
        return postflop(ctx, &rng)
    }

    // MARK: Preflop

    private func preflop(_ ctx: DecisionContext, _ rng: inout SeededRNG) -> Decision {
        let hole = ctx.hole
        let menu = ctx.menu
        guard let l = ctx.legal else { return Decision(.fold) }
        let raises = ctx.state.actions.filter { $0.street == .preflop && $0.kind == .raise }.count
        let toCall = Chips.bb(l.toCall)
        func pass(_ why: String) -> Decision { Decision(ActionMenu.passive(for: ctx.state), meta: DecisionMeta(reasoning: why)) }
        func pick(_ o: MenuOption?, _ why: String) -> Decision {
            guard let o else { return pass(why) }
            return Decision(o.action, meta: DecisionMeta(reasoning: why))
        }
        func inRange(_ r: String) -> Bool { rng.unit() < Self.weight(r, hole) }
        func jamOrCall(_ why: String) -> Decision {
            if toCall > 20, let jam = menu.aggressive.last { return pick(jam, why) }
            if toCall > 20 { return pick(menu.first(.call), why) }
            return pick(menu.sized(2.5) ?? menu.first(.call), why)
        }

        if ctx.seat == 0 {
            if ctx.state.actions.isEmpty {
                return inRange(RangeLibrary.sbOpen) ? pick(menu.sized(2.5), "In my button opening range: raise.")
                                                    : Decision(.fold, meta: DecisionMeta(reasoning: "Outside my opening range."))
            }
            if inRange(Self.premium) { return jamOrCall("Premium hand facing a raise: re-raise.") }
            if inRange(RangeLibrary.btnCallVs3bet) && toCall <= 12 { return pick(menu.first(.call), "Good enough to call the re-raise.") }
            return pass("Not strong enough to continue vs. the re-raise.")
        }

        // Big blind.
        if raises == 0 {
            return inRange(RangeLibrary.bb3betVsBtn) ? pick(menu.sized(4), "Raise the limp for value.") : pass("Check my option.")
        }
        if raises == 1 && Chips.bb(l.currentBet) <= 4 {
            if inRange(RangeLibrary.bb3betVsBtn) { return pick(menu.sized(3), "3-bet: in my value/bluff 3-bet range.") }
            if inRange(RangeLibrary.bbCallVsSb) { return pick(menu.first(.call), "Defend the big blind: call.") }
            return pass("Too weak to defend.")
        }
        if inRange(Self.premium) { return jamOrCall("Premium hand: get it in.") }
        let callRange = raises >= 2 ? Self.fourBetCall : Self.strong
        if inRange(callRange) && toCall <= 25 { return pick(menu.first(.call), "Strong enough to call this size.") }
        return pass("Large raise and my hand is not strong enough.")
    }

    // MARK: Postflop

    /// Plausible preflop range for `seat` given its preflop line.
    static func preflopRange(of seat: Int, in state: HandState) -> (text: String, label: String) {
        let pre = state.actions.filter { $0.street == .preflop }
        let raisesBy = pre.filter { $0.seat == seat && $0.kind == .raise }.count
        let anyRaise = pre.contains { $0.kind == .raise }
        if raisesBy >= 2 { return (premium, "4-bet range") }
        if seat == 0 {
            if raisesBy == 1 {
                let reraised = pre.contains { $0.seat == 1 && $0.kind == .raise }
                return reraised ? (RangeLibrary.btnCallVs3bet, "3-bet calling range") : (RangeLibrary.sbOpen, "button open range")
            }
            return anyRaise ? (RangeLibrary.btnCallVs3bet, "calling range") : (anyTwo, "limping range")
        }
        if raisesBy == 1 { return anyRaise && pre.first?.kind == .raise ? (RangeLibrary.bb3betVsBtn, "3-bet range") : (strong, "raising range") }
        return anyRaise ? (RangeLibrary.bbCallVsSb, "big blind defend range") : (anyTwo, "checked big blind range")
    }

    private func postflop(_ ctx: DecisionContext, _ rng: inout SeededRNG) -> Decision {
        let state = ctx.state
        let menu = ctx.menu
        guard let l = ctx.legal else { return Decision(.fold) }
        let villain = Self.preflopRange(of: ctx.opponent, in: state)
        var eq = (try? GTOCore.equity(hand: ctx.hole, board: state.board, range: villain.text, samples: 3000)) ?? 0.5
        let villainAggression = state.actions.filter { $0.street != .preflop && $0.seat == ctx.opponent && $0.kind != .call && $0.kind != .check }.count
        eq = max(0, eq - 0.07 * Double(villainAggression))
        let eqText = "Equity \(Int((eq * 100).rounded()))% vs. \(villain.label)"
        func pick(_ o: MenuOption?, _ why: String) -> Decision {
            guard let o else { return Decision(ActionMenu.passive(for: state), meta: DecisionMeta(reasoning: why)) }
            return Decision(o.action, meta: DecisionMeta(reasoning: "\(eqText): \(why)"))
        }

        if l.toCall > 0 {
            let odds = Double(l.toCall) / Double(state.pot + l.toCall)
            if eq >= 0.85, let r = menu.sized(0.75) { return pick(r, "raise for value.") }
            if eq >= odds + 0.05 { return pick(menu.first(.call), "beats pot odds of \(Int((odds * 100).rounded()))%; call.") }
            return pick(menu.first(.fold), "below pot odds of \(Int((odds * 100).rounded()))%; fold.")
        }
        let pfa = state.actions.last { $0.street == .preflop && $0.kind == .raise }?.seat
        if eq >= 0.7 { return pick(menu.sized(0.75), "value bet.") }
        if state.street == .flop && pfa == ctx.seat && eq >= 0.45 { return pick(menu.sized(0.33), "continuation bet.") }
        if eq < 0.25 && state.street != .river && rng.unit() < 0.15 { return pick(menu.sized(0.5), "occasional bluff.") }
        return pick(menu.first(.check), "check.")
    }
}
