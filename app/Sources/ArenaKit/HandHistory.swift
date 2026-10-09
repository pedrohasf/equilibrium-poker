import Foundation
import SolverKit

/// One step of a hand replay: the table right after `action` (or the initial blinds).
public struct ReplayStep: Sendable, Identifiable {
    public var id: Int
    public var state: HandState
    public var action: ActionRecord?
    public var caption: String
}

public enum HandReplay {
    /// Re-runs the recorded actions through the engine, yielding one snapshot per action.
    public static func steps(_ h: HandRecord, names: [String]) -> [ReplayStep] {
        var state = h.initialState
        let seatName = { (s: Int) in names[h.seatPlayers[s]] }
        var out = [ReplayStep(id: 0, state: state, action: nil,
                              caption: "\(seatName(0)) posts 0.5, \(seatName(1)) posts 1")]
        for (i, a) in h.actions.enumerated() {
            guard (try? state.apply(a.action, meta: a.meta)) != nil else { break }
            out.append(ReplayStep(id: i + 1, state: state, action: a, caption: "\(seatName(a.seat)) \(HandHistoryFormatter.verb(a))"))
        }
        return out
    }
}

/// PokerStars-flavoured text hand histories.
public enum HandHistoryFormatter {
    static func verb(_ a: ActionRecord) -> String {
        let allIn = a.allIn ? " and is all-in" : ""
        switch a.kind {
        case .fold: return "folds"
        case .check: return "checks"
        case .call: return "calls \(Chips.text(a.amount))\(allIn)"
        case .bet: return "bets \(Chips.text(a.to))\(allIn)"
        case .raise: return "raises to \(Chips.text(a.to))\(allIn)"
        }
    }

    /// Probability per menu option for a decision-model action ("    »   31%  call   Call 1.5 bb ◀ played").
    static func decisionLines(_ t: DecisionTrace) -> [String] {
        let w = t.options.map(\.key.count).max() ?? 4
        var out = t.options.map { o -> String in
            let p = o.probability.map { String(format: "%3.0f%%", $0 * 100) } ?? "   –"
            let bar = String(repeating: "█", count: Int(((o.probability ?? 0) * 20).rounded()))
            var line = "    » \(p) \(o.key.padding(toLength: w, withPad: " ", startingAt: 0))  \(bar)".replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if o.key == t.playedKey { line += "  ◀ played" + (t.mode == .mixed && o.key != t.choiceKey ? " (sampled)" : "") }
            else if o.key == t.choiceKey { line += "  (model's top choice)" }
            return line
        }
        var head = "    » decision model (\(t.mode.rawValue))"
        if let c = t.confidence { head += String(format: ", confidence %.0f%%", c * 100) }
        if let c = t.choiceKey, t.choiceIndex == nil { head += ", returned unknown key '\(c)'" }
        out.insert(head, at: 0)
        return out
    }

    public static func format(_ h: HandRecord, match: MatchRecord, includeReasoning: Bool = false) -> String {
        let names = match.players.map(\.id)
        let seatName = { (s: Int) in names[h.seatPlayers[s]] }
        let holes = h.holeCards
        let runout = h.runoutCards
        var lines: [String] = []
        let df = ISO8601DateFormatter()
        lines.append("Equilibrium Arena Hand #\(h.number) (match \(match.id), deal \(h.deal + 1)\(match.config.duplicate ? ", replica \(h.replica == 0 ? "A" : "B")" : "")): Hold'em No Limit (0.5/1 bb) - \(df.string(from: match.createdAt))")
        lines.append("Table 'Arena' 2-max Seat #1 is the button")
        for s in 0..<2 {
            lines.append("Seat \(s + 1): \(seatName(s)) (\(Chips.text(h.config.stacks[s])) bb in chips)")
        }
        lines.append("\(seatName(0)): posts small blind \(Chips.text(h.config.smallBlind))")
        lines.append("\(seatName(1)): posts big blind \(Chips.text(h.config.bigBlind))")
        lines.append("*** HOLE CARDS ***")
        for s in 0..<2 { lines.append("Dealt to \(seatName(s)) [\(holes[s].text)]") }

        var street = Street.preflop
        func header(_ st: Street) {
            switch st {
            case .preflop: break
            case .flop: lines.append("*** FLOP *** [\(Array(runout.prefix(3)).text)]")
            case .turn: lines.append("*** TURN *** [\(Array(runout.prefix(3)).text)] [\(runout[3])]")
            case .river: lines.append("*** RIVER *** [\(Array(runout.prefix(4)).text)] [\(runout[4])]")
            }
        }
        for a in h.actions {
            while street < a.street {
                street = Street(rawValue: street.rawValue + 1)!
                header(street)
            }
            lines.append("\(seatName(a.seat)): \(verb(a))")
            if includeReasoning, let t = a.meta?.decision {
                lines.append(contentsOf: decisionLines(t))
            } else if includeReasoning, let r = a.meta?.reasoning, !r.isEmpty {
                lines.append("    » " + r.replacingOccurrences(of: "\n", with: " "))
            }
            if let m = a.meta, m.fallback {
                lines.append("    ! invalid/failed decision replaced by \(a.kind.rawValue)\(m.errorMessage.map { " (\($0))" } ?? "")")
            }
        }
        let r = h.result
        if r.showdown {
            while street < .river {
                street = Street(rawValue: street.rawValue + 1)!
                header(street)
            }
        }
        if let s = r.uncalledSeat, r.uncalledAmount > 0 {
            lines.append("Uncalled bet (\(Chips.text(r.uncalledAmount))) returned to \(seatName(s))")
        }
        if r.showdown {
            lines.append("*** SHOW DOWN ***")
            for s in 0..<2 {
                lines.append("\(seatName(s)): shows [\(holes[s].text)]\(r.categories.map { " (\($0[s].lowercased()))" } ?? "")")
            }
            if let eq = r.allInEquity {
                lines.append("All-in equity: \(seatName(0)) \(String(format: "%.1f%%", eq[0] * 100)), \(seatName(1)) \(String(format: "%.1f%%", eq[1] * 100))")
            }
        }
        for w in r.winners {
            lines.append("\(seatName(w)) collected \(Chips.text(r.pot / r.winners.count)) from pot")
        }
        lines.append("*** SUMMARY ***")
        lines.append("Total pot \(Chips.text(r.pot)) bb | Rake 0")
        if h.boardCount > 0 { lines.append("Board [\(h.board.text)]") }
        for s in 0..<2 {
            let role = s == 0 ? " (button) (small blind)" : " (big blind)"
            let folded = h.actions.first { $0.seat == s && $0.kind == .fold }
            var outcome: String
            if let f = folded {
                outcome = f.street == .preflop ? "folded before Flop" : "folded on the \(f.street.name)"
            } else if r.showdown {
                outcome = "showed [\(holes[s].text)] and " + (r.winners.contains(s) ? "won (\(Chips.text(r.pot / r.winners.count)))" : "lost")
                if let c = r.categories?[s] { outcome += " with \(c.lowercased())" }
            } else {
                outcome = "collected (\(Chips.text(r.pot)))"
            }
            let netText = String(format: "%+.2f bb", Chips.bb(r.net[s]))
            lines.append("Seat \(s + 1): \(seatName(s))\(role) \(outcome) — net \(netText)")
        }
        return lines.joined(separator: "\n")
    }
}
