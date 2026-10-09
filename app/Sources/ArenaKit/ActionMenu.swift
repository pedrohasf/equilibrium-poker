import Foundation

/// One numbered choice offered to a player.
public struct MenuOption: Codable, Hashable, Sendable {
    public enum Sizing: Codable, Hashable, Sendable {
        /// Preflop: multiple of the current bet (2.5x, 3x, 4x).
        case multiple(Double)
        /// Postflop: fraction of the pot.
        case potFraction(Double)
        case allIn
    }

    public var action: ArenaAction
    public var label: String
    public var sizing: Sizing?

    public var isAllIn: Bool { sizing == .allIn }
}

/// Builds the discrete menu of legal actions shown to players (decision models and bots alike).
public enum ActionMenu {
    public static let preflopMultiples: [Double] = [2.5, 3, 4]
    public static let postflopFractions: [Double] = [0.33, 0.5, 0.75, 1.0, 1.5]
    /// Raise sizes are rounded to this many chips (0.1 bb).
    public static let rounding = 10

    public static func build(for state: HandState) -> [MenuOption] {
        guard let l = state.legalActions() else { return [] }
        var out: [MenuOption] = []
        if l.canFold { out.append(MenuOption(action: .fold, label: "Fold")) }
        if l.canCheck { out.append(MenuOption(action: .check, label: "Check")) }
        if l.canCall {
            out.append(MenuOption(action: .call, label: "Call \(Chips.text(l.toCall)) bb" + (l.callIsAllIn ? " (all-in)" : "")))
        }
        guard l.canRaise else { return out }

        let verb = l.isBet ? "Bet" : "Raise to"
        let kind: ArenaAction.Kind = l.isBet ? .bet : .raise
        var used: Set<Int> = []
        func add(_ rawTo: Double, _ sizing: MenuOption.Sizing, _ note: String) {
            var to = Int((rawTo / Double(rounding)).rounded()) * rounding
            to = max(to, l.minTo)
            guard to < l.maxTo, !used.contains(to) else { return }
            used.insert(to)
            out.append(MenuOption(action: ArenaAction(kind, to: to), label: "\(verb) \(Chips.text(to)) bb (\(note))", sizing: sizing))
        }

        if state.street == .preflop {
            for m in preflopMultiples {
                add(Double(l.currentBet) * m, .multiple(m), "\(trim(m))x")
            }
        } else {
            let pot = Double(state.pot)
            for f in postflopFractions {
                let to = l.isBet ? f * pot : Double(l.currentBet) + f * (pot + Double(l.toCall))
                add(to, .potFraction(f), "\(Int((f * 100).rounded()))% pot")
            }
        }
        out.append(MenuOption(action: ArenaAction(kind, to: l.maxTo), label: "All-in \(Chips.text(l.maxTo)) bb", sizing: .allIn))
        return out
    }

    /// The check-if-possible-else-fold default.
    public static func passive(for state: HandState) -> ArenaAction {
        state.legalActions()?.canCheck == true ? .check : .fold
    }

    private static func trim(_ x: Double) -> String {
        x == x.rounded() ? String(Int(x)) : String(format: "%.1f", x)
    }
}

public extension Array where Element == MenuOption {
    func first(_ kind: ArenaAction.Kind) -> MenuOption? { first { $0.action.kind == kind } }
    var passive: MenuOption? { first(.check) ?? first(.call) }
    var aggressive: [MenuOption] { filter { $0.action.isAggressive } }

    /// The aggressive option whose raise-to is closest to `to` chips.
    func closestRaise(to: Int) -> MenuOption? {
        aggressive.min { abs($0.action.to - to) < abs($1.action.to - to) }
    }

    /// Option closest to a pot fraction (postflop) or multiple (preflop); falls back to all-in.
    func sized(_ target: Double) -> MenuOption? {
        let scored = aggressive.compactMap { o -> (MenuOption, Double)? in
            switch o.sizing {
            case .potFraction(let f): return (o, abs(f - target))
            case .multiple(let m): return (o, abs(m - target))
            default: return nil
            }
        }
        return scored.min { $0.1 < $1.1 }?.0 ?? aggressive.last
    }
}
