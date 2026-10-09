import Foundation
import LLMKit
import SolverKit

/// Builds the prompts shown to LLM players. Bump `version` whenever wording changes so runs
/// produced with different prompts can be told apart.
public enum PromptBuilder {
    public static let version = 1

    public static let system = """
    You are a world-class heads-up No-Limit Texas Hold'em player. You will be given a single postflop \
    decision from a hand and must pick the action with the highest expected value against a strong, \
    balanced (game-theory-optimal) opponent.

    Conventions:
    - All amounts are in big blinds (bb). Stacks were 100 bb at the start of the hand.
    - Cards use rank + suit: A K Q J T 9 … 2 and s = spades, h = hearts, d = diamonds, c = clubs.
    - "Pot" includes every chip already committed, including a bet you are facing.
    - Bet sizes are shown as a fraction of the pot before the bet.
    - You may only choose one of the numbered legal actions; sizes are fixed.

    Think like a solver: consider both ranges given the action, your hand's equity and blockers, \
    pot odds, and which hands in your range should take each action. Keep your reasoning brief \
    (at most a short paragraph). Then end your reply with a final line containing only a JSON object \
    of the form {"action": N}, where N is the number of the chosen legal action.
    """

    /// Text shown for hero's cards and the board, e.g. "As Kd".
    static func cards(_ cs: [String]) -> String { cs.joined(separator: " ") }

    public static func names(for d: Decision) -> [String] {
        var n = d.positions
        n[d.heroSeat] += " (you)"
        return n
    }

    /// Human-readable street-by-street history, one line per street.
    public static func historyLines(_ d: Decision, names: [String]? = nil) -> [String] {
        let names = names ?? self.names(for: d)
        var lines: [String] = []
        for street in Street.allCases where street <= d.street {
            let boardText: String
            switch street {
            case .flop: boardText = cards(Array(d.board.prefix(3)))
            case .turn: boardText = d.board.count > 3 ? d.board[3] : ""
            case .river: boardText = d.board.count > 4 ? d.board[4] : ""
            }
            let entries = d.history.filter { $0.street == street && $0.action != nil }
            let potStart = street == .flop ? d.flopPot
                : (d.history.first { $0.street == street }?.potBefore ?? entries.first?.potBefore ?? d.pot)
            let acts = entries.map { $0.text(names: names) }
            let body = acts.isEmpty ? "(no action yet)" : acts.joined(separator: ", ") + (street == d.street ? "" : ".")
            lines.append("\(street.title) \(boardText) (pot \(BB.fmt(potStart)) bb): \(body)")
        }
        return lines
    }

    public static func user(_ d: Decision) -> String {
        let names = self.names(for: d)
        let heroRole = d.heroIsIP ? "in position (acts last on each street)" : "out of position (acts first on each street)"
        let heroStack = d.stacks[d.heroSeat], villainStack = d.stacks[1 - d.heroSeat]
        var s = """
        Game: heads-up No-Limit Hold'em, 100 bb effective stacks (6-max positions, everyone else folded preflop).
        Preflop: \(d.preflopSummary)
        You are \(d.heroPosition), \(heroRole). Your opponent is \(d.villainPosition).

        Your hand: \(cards(Card.parseList(d.heroCards)?.map(\.description) ?? [d.heroCards]))
        Board: \(cards(d.board))

        Action so far:
        \(historyLines(d, names: names).joined(separator: "\n"))

        Decision: \(d.street.rawValue), you to act. Pot: \(BB.fmt(d.pot)) bb.
        Stacks behind: you \(BB.fmt(heroStack)) bb, \(d.villainPosition) \(BB.fmt(villainStack)) bb.
        """
        if d.facingBet {
            let odds = d.toCall / (d.pot + d.toCall)
            s += "\nYou are facing a bet: \(BB.fmt(d.toCall)) bb to call (you need \(BB.pct(odds)) equity to call)."
        }
        s += "\n\nLegal actions:\n"
        for (i, a) in d.actions.enumerated() {
            s += "\(i + 1). \(a.detailedLabel)\n"
        }
        s += "\nReason briefly, then end with {\"action\": <number>}."
        return s
    }

    public static func messages(_ d: Decision) -> [ChatMessage] {
        [.system(system), .user(user(d))]
    }

    /// Follow-up used once when an answer could not be parsed.
    public static func repair(_ d: Decision) -> String {
        "I could not find a valid action in your reply. Reply with only {\"action\": N} where N is 1–\(d.actions.count)."
    }
}

/// Extracts the chosen action from a free-form model reply.
public enum ResponseParser {
    /// Returns the 0-based action index, or nil if no valid action could be identified.
    public static func parse(_ text: String, actions: [SpotAction]) -> Int? {
        let n = actions.count
        func fromNumber(_ x: Int) -> Int? { (1...max(1, n)).contains(x) && n > 0 ? x - 1 : nil }

        // 1. The last JSON object with an "action" (or "choice") field: number, numeric string or label.
        if let obj = LLMParsing.lastJSONObject(in: text) {
            for key in ["action", "choice", "Action", "answer"] {
                guard let v = obj[key] else { continue }
                if let num = v as? NSNumber, let i = fromNumber(num.intValue), Double(num.intValue) == num.doubleValue { return i }
                if let str = v as? String {
                    if let x = Int(str.trimmingCharacters(in: .whitespaces)), let i = fromNumber(x) { return i }
                    if let i = matchLabel(str, actions) { return i }
                }
            }
        }
        // 2. Regex fallbacks on the tail of the reply: `"action": 3`, `action 3`, `Action: #3`.
        let patterns = [#""?action"?\s*[:=]\s*"?#?(\d+)(?!\.?\d)"#, #"\baction\s*(?:number|#)?\s*[:=]?\s*#?(\d+)(?!\.?\d)\b"#]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) {
                let ns = text as NSString
                let ms = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
                if let m = ms.last, let x = Int(ns.substring(with: m.range(at: 1))), let i = fromNumber(x) { return i }
            }
        }
        // 3. Last non-empty line exactly equal to a label (or "3." / "3").
        if let last = text.split(whereSeparator: \.isNewline).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let t = last.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters).subtracting(CharacterSet(charactersIn: ".")))
            if let x = Int(t.trimmingCharacters(in: CharacterSet(charactersIn: ". "))), let i = fromNumber(x) { return i }
            if let i = matchLabel(t, actions) { return i }
        }
        return nil
    }

    /// Matches a label like "Call 6.8 bb", "call", "bet 75%", "Raise to 25".
    static func matchLabel(_ raw: String, _ actions: [SpotAction]) -> Int? {
        let s = normalize(raw)
        guard !s.isEmpty else { return nil }
        if let i = actions.firstIndex(where: { normalize($0.label) == s || normalize($0.detailedLabel) == s }) { return i }
        // Unique kind match ("call", "fold", "check", "all-in").
        let kindWords: [(String, ActionKind)] = [("fold", .fold), ("check", .check), ("call", .call), ("allin", .allin), ("all in", .allin), ("jam", .allin), ("shove", .allin)]
        for (w, k) in kindWords where s == w || s.hasPrefix(w + " ") {
            let idx = actions.indices.filter { actions[$0].kind == k }
            if idx.count == 1 { return idx[0] }
        }
        // Bet/raise with a size: pick the closest amount among aggressive actions.
        if s.hasPrefix("bet") || s.hasPrefix("raise") {
            let aggressive = actions.indices.filter { actions[$0].kind.isAggressive }
            let nums = s.split(whereSeparator: { !($0.isNumber || $0 == ".") }).compactMap { Double($0) }
            if let x = nums.first, !aggressive.isEmpty {
                if s.contains("%") {
                    return aggressive.min { abs(actions[$0].potFraction * 100 - x) < abs(actions[$1].potFraction * 100 - x) }
                }
                let key: (Int) -> Double = { s.hasPrefix("raise") ? actions[$0].to : actions[$0].amount }
                return aggressive.min { abs(key($0) - x) < abs(key($1) - x) }
            }
            if aggressive.count == 1 { return aggressive[0] }
        }
        return nil
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "bb", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
    }
}

/// Rough pre-run cost estimate from prompt length and an assumed completion budget.
public enum CostEstimator {
    /// Expected completion tokens per decision (visible answer + hidden reasoning) by reasoning effort.
    public static func completionTokens(reasoningEffort: String?) -> Int {
        switch reasoningEffort {
        case "minimal": return 350
        case "low": return 1_200
        case "medium": return 3_000
        case "high": return 7_000
        default: return 900
        }
    }

    /// ~4 characters per token for English prompts.
    public static func promptTokens(_ d: Decision) -> Int {
        (PromptBuilder.system.count + PromptBuilder.user(d).count) / 4 + 12
    }

    public struct Estimate: Sendable, Hashable {
        public var promptTokens: Int
        public var completionTokens: Int
        /// nil when the model's prices are unknown.
        public var usd: Double?
    }

    /// Decision models bill input tokens only (output is free).
    public static func decisionEstimate(decisions: [Decision], promptPrice: Double?) -> Estimate {
        let p = decisions.reduce(0) { $0 + DecisionStateBuilder.estimatedInputTokens($1) }
        return Estimate(promptTokens: p, completionTokens: 0, usd: promptPrice.map { Double(p) * $0 })
    }

    public static func estimate(decisions: [Decision], promptPrice: Double?, completionPrice: Double?,
                                reasoningEffort: String?) -> Estimate {
        let p = decisions.reduce(0) { $0 + promptTokens($1) }
        let c = decisions.count * completionTokens(reasoningEffort: reasoningEffort)
        var usd: Double?
        if let pp = promptPrice, let cp = completionPrice { usd = Double(p) * pp + Double(c) * cp }
        return Estimate(promptTokens: p, completionTokens: c, usd: usd)
    }
}
