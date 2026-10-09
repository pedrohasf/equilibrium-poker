import Foundation
import OpenRouterKit
import SolverKit

// MARK: - Trace stored with every decision-model action

/// What a System One decision model saw and answered for one decision (kept in hand histories).
public struct DecisionTrace: Codable, Hashable, Sendable {
    public struct Option: Codable, Hashable, Sendable {
        /// Criteria key sent to the model ("fold", "raise_to_7.5bb", "bet_75pct", "allin").
        public var key: String
        /// Menu label ("Raise to 7.5 bb (3x)").
        public var label: String
        /// Probability returned by the model (nil when the model omitted it).
        public var probability: Double?

        public init(key: String, label: String, probability: Double? = nil) {
            self.key = key
            self.label = label
            self.probability = probability
        }
    }

    public var mode: DecisionMode
    /// Options in menu order.
    public var options: [Option]
    /// The model's own top choice (raw key as returned).
    public var choiceKey: String?
    /// The key actually played (differs from `choiceKey` when sampling in mixed mode).
    public var playedKey: String?
    public var confidence: Double?
    /// Compact JSON state that was sent.
    public var state: String?

    public init(mode: DecisionMode, options: [Option], choiceKey: String? = nil, playedKey: String? = nil,
                confidence: Double? = nil, state: String? = nil) {
        self.mode = mode
        self.options = options
        self.choiceKey = choiceKey
        self.playedKey = playedKey
        self.confidence = confidence
        self.state = state
    }

    public var playedIndex: Int? { playedKey.flatMap { k in options.firstIndex { $0.key == k } } }
    public var choiceIndex: Int? { choiceKey.flatMap { k in options.firstIndex { $0.key == k } } }

    /// "fold 12% · call 63% · raise_to_7.5bb 25%"
    public var summary: String {
        options.map { o in "\(o.key) " + (o.probability.map { "\(Int(($0 * 100).rounded()))%" } ?? "–") }
            .joined(separator: " · ")
    }
}

// MARK: - Player

/// A System One decision model (OpenRouter `output_modalities: decisions`) choosing from the action menu.
///
/// Each decision sends a structured JSON state plus one `choice` question whose criteria are the
/// legal actions. In `.argmax` mode the returned `choice` is played; in `.mixed` mode an action is
/// sampled from the returned probabilities with the decision's deterministic seed.
public struct DecisionModelPlayer: ArenaPlayer {
    public let model: String
    public let mode: DecisionMode
    public let includeMatchSummary: Bool
    let client: any DecisionProvider

    public static let questionID = "action"

    public init(model: String, mode: DecisionMode = .argmax, includeMatchSummary: Bool = false, client: any DecisionProvider) {
        self.model = model
        self.mode = mode
        self.includeMatchSummary = includeMatchSummary
        self.client = client
    }

    public var name: String { "dm:\(model)" + mode.suffix }

    public func decide(_ ctx: DecisionContext) async throws -> Decision {
        let keys = DecisionPrompt.keys(for: ctx.menu)
        let state = DecisionPrompt.state(for: ctx, includeSummary: includeMatchSummary, enhanced: mode == .plus)
        let question = DecisionPrompt.question(for: ctx, keys: keys, enhanced: mode == .plus)
        let stateText = DecisionPrompt.compactJSON(state)
        var meta = DecisionMeta()
        var trace = DecisionTrace(mode: mode, options: zip(keys, ctx.menu).map { .init(key: $0, label: $1.label) }, state: stateText)

        for attempt in 0..<2 {
            let result: DecideResult
            do {
                result = try await client.decide(model: model, state: state, questions: [Self.questionID: question])
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                meta.errors += 1
                meta.errorMessage = error.localizedDescription
                if attempt == 0 { continue }
                break
            }
            meta.raw.append(result.raw)
            meta.latency += result.latency
            meta.promptTokens += result.usage.promptTokens
            meta.completionTokens += result.usage.completionTokens
            meta.cost += result.usage.cost

            guard let answer = result.answers[Self.questionID] ?? (result.answers.count == 1 ? result.answers.values.first : nil),
                  case let .choice(choice, confidence, probabilities) = answer else {
                meta.errors += 1
                meta.errorMessage = "no choice answer in the response"
                continue
            }
            let probs = DecisionPrompt.align(probabilities, keys: keys)
            trace.choiceKey = choice
            trace.confidence = confidence
            for i in trace.options.indices { trace.options[i].probability = probs[i] }

            guard let picked = pick(choice: choice, probabilities: probs, keys: keys, seed: ctx.rngSeed) else {
                meta.errors += 1
                meta.errorMessage = "unknown action key '\(choice)'"
                continue
            }
            trace.playedKey = keys[picked]
            meta.menuChoice = picked + 1
            meta.reasoning = DecisionPrompt.reasoning(trace)
            meta.decision = trace
            return Decision(ctx.menu[picked].action, meta: meta)
        }
        meta.fallback = true
        meta.decision = trace
        let passive = ActionMenu.passive(for: ctx.state)
        if let i = ctx.menu.firstIndex(where: { $0.action == passive }) { meta.decision?.playedKey = keys[i] }
        return Decision(passive, meta: meta)
    }

    /// Index of the option to play, or nil when the model's answer is unusable.
    func pick(choice: String, probabilities: [Double?], keys: [String], seed: UInt64) -> Int? {
        guard let chosen = DecisionPrompt.index(of: choice, in: keys) else { return nil }
        guard mode == .mixed else { return chosen }
        return DecisionPrompt.sample(probabilities, seed: seed) ?? chosen
    }
}

// MARK: - State & question

public enum DecisionPrompt {
    // MARK: Keys

    /// Readable, unique slug per menu option: fold, check, call, raise_to_7.5bb, bet_75pct, allin.
    public static func keys(for menu: [MenuOption]) -> [String] {
        var used: [String: Int] = [:]
        return menu.map { o in
            var k: String
            switch o.action.kind {
            case .fold: k = "fold"
            case .check: k = "check"
            case .call: k = "call"
            case .bet, .raise:
                switch o.sizing {
                case .allIn: k = "allin"
                case .potFraction(let f) where o.action.kind == .bet: k = "bet_\(Int((f * 100).rounded()))pct"
                default: k = "\(o.action.kind == .bet ? "bet" : "raise_to")_\(Chips.text(o.action.to))bb"
                }
            }
            used[k, default: 0] += 1
            if used[k]! > 1 { k += "_\(used[k]!)" }
            return k
        }
    }

    /// Case/whitespace-insensitive lookup of a returned key.
    public static func index(of key: String, in keys: [String]) -> Int? {
        let n = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return keys.firstIndex(of: n) ?? keys.firstIndex { $0.lowercased() == n }
    }

    /// Probabilities in menu order (unknown keys dropped).
    public static func align(_ probs: [String: Double], keys: [String]) -> [Double?] {
        var out = [Double?](repeating: nil, count: keys.count)
        for (k, p) in probs {
            if let i = index(of: k, in: keys), p.isFinite { out[i] = (out[i] ?? 0) + max(0, p) }
        }
        return out
    }

    /// Seeded draw from (unnormalised) probabilities; nil when there is no mass.
    public static func sample(_ probs: [Double?], seed: UInt64) -> Int? {
        let w = probs.map { $0 ?? 0 }
        let total = w.reduce(0, +)
        guard total > 0 else { return nil }
        var rng = SeededRNG(seed: SeededRNG.mix(seed, 0xD3C1_5104))
        var x = rng.unit() * total
        for (i, p) in w.enumerated() where p > 0 {
            x -= p
            if x < 0 { return i }
        }
        return w.lastIndex { $0 > 0 }
    }

    static func reasoning(_ t: DecisionTrace) -> String {
        var s = t.summary
        if let c = t.confidence { s += String(format: " (confidence %.0f%%)", c * 100) }
        if t.mode == .mixed, let p = t.playedKey, p != t.choiceKey { s += " → sampled \(p)" }
        return s
    }

    // MARK: Question

    public static func question(for ctx: DecisionContext, keys: [String]? = nil, enhanced: Bool = false) -> DecisionQuestion {
        let keys = keys ?? self.keys(for: ctx.menu)
        var criteria: [String: String] = [:]
        for (k, o) in zip(keys, ctx.menu) { criteria[k] = describe(o, ctx: ctx) }
        let instructions = """
        You are the hero in a heads-up No-Limit Texas Hold'em hand (amounts in big blinds, bb). Using the hero's hole cards, \
        the board, position, the betting so far and the pot odds in the state, choose the hero's next action — the one that \
        wins the most big blinds in the long run against this opponent, as a strong game-theory-aware player would. \
        Exactly one of the listed legal actions must be chosen.
        """
        guard enhanced else { return .choice(instructions: instructions, criteria: criteria) }
        let s = ctx.state, me = ctx.seat
        let effectiveBB = Chips.bb(min(s.stacks[me] + s.streetContrib[me], s.stacks[1 - me] + s.streetContrib[1 - me]))
        var extra = ""
        if s.boardCount >= 3 {
            extra = " Hand strength matters most in big pots: with the nuts or a near-nut hand on the river, choose the action that extracts"
                + " the most chips (usually a bet or raise, including large sizes); on earlier streets with a very strong hand, just calling"
                + " can be right when it keeps the opponent's bluffs and weaker hands in, especially on dry or paired boards."
        } else if effectiveBB <= 30 {
            extra = " Stack depth changes preflop strategy: with 25 big blinds or less, a small raise that commits a large part of the stack"
                + " is rarely best — the strong options are usually to limp or call, to fold, or to go all-in (which wins the blinds"
                + " immediately when the opponent folds). Facing an all-in, call when the hand is strong enough given the price."
        }
        return .choice(instructions: instructions + extra, criteria: criteria)
    }

    /// Self-contained description of one option (the model never sees the question id or menu numbers).
    public static func describe(_ o: MenuOption, ctx: DecisionContext) -> String {
        let s = ctx.state, me = ctx.seat, opp = 1 - me
        let pot = s.pot
        let toCall = ctx.legal?.toCall ?? 0
        func bb(_ c: Int) -> String { "\(Chips.text(c)) bb" }
        func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
        switch o.action.kind {
        case .fold:
            return "Fold: give up the hand now. The hero forfeits the \(bb(s.totalContrib[me])) already invested and the opponent wins the \(bb(pot)) pot."
        case .check:
            let next = s.street == .river && me == 0 ? "the hand goes to showdown" : (me == 1 && s.street != .preflop ? "the opponent then acts" : "the next card is dealt")
            return "Check: put no more chips in; the pot stays \(bb(pot)) and \(next). Keeps the pot small and the hero's \(bb(s.stacks[me])) stack intact."
        case .call:
            let after = pot + toCall
            var d = "Call \(bb(toCall)): match the opponent's bet; the pot becomes \(bb(after)). Needs at least \(pct(Double(toCall) / Double(max(1, after)))) equity to break even."
            if s.street == .preflop && me == 0 && s.currentBet == s.config.bigBlind { d = "Call \(bb(toCall)) (limp): complete the small blind to 1 bb; the pot becomes \(bb(after)) and the big blind may check or raise." }
            if ctx.legal?.callIsAllIn == true { d += " This call puts the hero all-in." }
            return d
        case .bet, .raise:
            let extra = o.action.to - s.streetContrib[me]
            let behind = s.stacks[me] - extra
            let potFrac = Double(extra - toCall) / Double(max(1, pot + toCall))
            if o.isAllIn {
                return "All-in: commit the hero's entire remaining stack (\(bb(s.stacks[me])) more, \(bb(o.action.to)) total this street), about \(String(format: "%.1f", Double(extra) / Double(max(1, pot))))x the current \(bb(pot)) pot. The opponent must call or fold."
            }
            if o.action.kind == .bet {
                return "Bet \(bb(o.action.to)) into the \(bb(pot)) pot (\(pct(Double(o.action.to) / Double(max(1, pot)))) of the pot). The hero keeps \(bb(behind)) behind; the opponent can fold, call or raise."
            }
            var size = ""
            switch o.sizing {
            case .multiple(let m): size = "\(trim(m))x the current bet of \(bb(s.currentBet))"
            case .potFraction: size = "a raise of about \(pct(potFrac)) of the pot after calling"
            default: break
            }
            let what = s.street == .preflop && s.currentBet == s.config.bigBlind && me == 0 ? "Open-raise" : (s.street == .preflop && s.streetContrib[opp] > s.config.bigBlind ? "Re-raise" : "Raise")
            return "\(what) to \(bb(o.action.to)) total this street (\(size)), putting \(bb(extra)) more in. The pot becomes \(bb(pot + extra)) and the hero keeps \(bb(behind)) behind."
        }
    }

    // MARK: State

    public static func state(for ctx: DecisionContext, includeSummary: Bool, enhanced: Bool = false) -> JSONValue {
        let s = ctx.state, me = ctx.seat, opp = 1 - ctx.seat
        let toCall = ctx.legal?.toCall ?? 0
        let effective = min(s.stacks[me], s.stacks[opp] + max(0, s.streetContrib[opp] - s.streetContrib[me]))
        let hole = ctx.hole

        var obj: [String: JSONValue] = [
            "format": .string("Heads-up No-Limit Texas Hold'em, blinds 0.5/1 bb. Both stacks are reset to \(Chips.text(s.config.stacks[me])) bb at the start of every hand. All amounts are in big blinds (bb)."),
            "objective": "Win as many big blinds as possible over many hands against the same opponent.",
            "hand_number": .number(Double(ctx.handNumber)),
            "street": .string(s.street.name.lowercased()),
            "hero_position": .string(me == 0
                ? "Button / small blind (BTN/SB): the hero acts FIRST preflop and LAST (in position) on the flop, turn and river."
                : "Big blind (BB): the hero acts LAST preflop and FIRST (out of position) on the flop, turn and river."),
            "hero_in_position_postflop": .bool(me == 0),
            "hero_hole_cards": .string(hole.text),
            "hero_hole_cards_spelled": .string(spelled(hole)),
            "board": board(s),
            "action_history": history(s, seat: me),
            "pot_bb": num(s.pot),
            "hero_stack_bb": num(s.stacks[me]),
            "opponent_stack_bb": num(s.stacks[opp]),
            "effective_stack_bb": num(effective),
            "hero_invested_this_street_bb": num(s.streetContrib[me]),
            "opponent_invested_this_street_bb": num(s.streetContrib[opp]),
            "to_call_bb": num(toCall),
            "spr": .number(round2(Double(effective) / Double(max(1, s.pot)))),
            "situation": .string(situation(ctx)),
        ]
        if hole.count == 2 { obj["hero_hand_class"] = .string(Combo(hole[0], hole[1]).handClass.description + handClassNote(hole)) }
        if toCall > 0 {
            let need = Double(toCall) / Double(s.pot + toCall)
            obj["pot_odds"] = .string("Calling \(Chips.text(toCall)) bb to win a pot of \(Chips.text(s.pot)) bb (\(Chips.text(s.pot + toCall)) bb after the call): the hero needs \(Int((need * 100).rounded()))% equity to break even.")
            obj["equity_needed_to_call"] = .number(round2(need))
        } else {
            obj["pot_odds"] = "Nothing to call: the hero can check for free."
        }
        if s.boardCount >= 3 {
            let cards = hole + s.board
            if let v = try? GTOCore.evaluate([cards]).first, !v.category.isEmpty {
                obj["hero_made_hand"] = .string(v.category)
            }
            obj["board_texture"] = .string(texture(s.board))
            if enhanced, let n = nutRanking(hole: hole, board: s.board) { obj["nut_ranking"] = .string(n.text); obj["holdings_that_beat_hero_now"] = .number(Double(n.beatenBy)) }
        }
        if includeSummary, let sum = ctx.matchSummary, !sum.isEmpty {
            obj["opponent_stats"] = .string(sum.replacingOccurrences(of: "\n", with: " "))
        }
        return .object(obj)
    }

    /// Exact count of opponent holdings that beat hero right now (pure card arithmetic).
    static func nutRanking(hole: [Card], board: [Card]) -> (beatenBy: Int, text: String)? {
        guard hole.count == 2, board.count >= 3 else { return nil }
        let dead = Set(hole + board)
        let opps = Combo.all.filter { !dead.contains($0.high) && !dead.contains($0.low) }
        guard let v = try? GTOCore.evaluate([hole + board] + opps.map { $0.cards + board }), let h = v.first else { return nil }
        let better = v.dropFirst().filter { $0 > h }.count
        if better == 0 { return (0, "hero holds the nuts right now (no holding beats it)") }
        let pct = 100.0 * Double(better) / Double(max(1, opps.count))
        return (better, "\(better) of \(opps.count) possible opponent holdings (\(String(format: "%.1f", pct))%) beat hero right now")
    }

    public static func compactJSON(_ v: JSONValue) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: e.encode(v), as: UTF8.self)) ?? ""
    }

    static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
    static func num(_ chips: Int) -> JSONValue { .number(round2(Chips.bb(chips))) }
    static func trim(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(format: "%.1f", x) }

    static let rankNames = ["Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Jack", "Queen", "King", "Ace"]
    static let suitNames = ["clubs", "diamonds", "hearts", "spades"]

    public static func spelled(_ cards: [Card]) -> String {
        cards.map { "\(rankNames[$0.rank.rawValue]) of \(suitNames[$0.suit.rawValue])" }.joined(separator: ", ")
    }

    static func handClassNote(_ hole: [Card]) -> String {
        if hole[0].rank == hole[1].rank { return " (pocket pair)" }
        return hole[0].suit == hole[1].suit ? " (suited)" : " (offsuit)"
    }

    static func board(_ s: HandState) -> JSONValue {
        let b = s.board
        guard !b.isEmpty else { return "none yet (preflop)" }
        var o: [String: JSONValue] = ["flop": .string(Array(b.prefix(3)).text)]
        if b.count >= 4 { o["turn"] = .string(b[3].description) }
        if b.count >= 5 { o["river"] = .string(b[4].description) }
        o["all_cards_spelled"] = .string(spelled(b))
        return .object(o)
    }

    static func texture(_ board: [Card]) -> String {
        var notes: [String] = []
        let suitCounts = Dictionary(grouping: board, by: \.suit).mapValues(\.count)
        let maxSuit = suitCounts.values.max() ?? 0
        switch maxSuit {
        case 5: notes.append("five cards of one suit (flush on board)")
        case 4: notes.append("four cards of one suit (one more of that suit makes a flush)")
        case 3: notes.append(board.count == 3 ? "monotone (all one suit; flushes possible)" : "three of one suit (flushes possible)")
        case 2: notes.append(board.count == 3 ? "two-tone (flush draws possible)" : "no flush possible yet (max two of a suit)")
        default: notes.append("rainbow (no flush draws)")
        }
        let rankCounts = Dictionary(grouping: board, by: \.rank).mapValues(\.count)
        if let m = rankCounts.values.max(), m >= 3 { notes.append("trips on board") }
        else if rankCounts.values.filter({ $0 == 2 }).count >= 2 { notes.append("two pair on board") }
        else if rankCounts.values.contains(2) { notes.append("paired board") }
        else { notes.append("unpaired") }
        // Straight possible: any 5-rank window (ace counts low too) holding three distinct board ranks.
        var ranks = Set(board.map { $0.rank.rawValue + 2 })
        if ranks.contains(14) { ranks.insert(1) }
        let straightPossible = (1...10).contains { lo in (lo...(lo + 4)).filter { ranks.contains($0) }.count >= 3 }
        notes.append(straightPossible ? "straights possible" : "no straight possible")
        let high = board.map(\.rank).max()!
        notes.append("high card \(rankNames[high.rawValue].lowercased())")
        return notes.joined(separator: ", ")
    }

    /// Betting so far by street, from the hero's point of view.
    static func history(_ s: HandState, seat: Int) -> JSONValue {
        func who(_ x: Int) -> String { (x == seat ? "Hero" : "Opponent") + (x == 0 ? " (BTN/SB)" : " (BB)") }
        var out: [String: JSONValue] = [:]
        for street in Street.allCases where street <= s.street || s.actions.contains(where: { $0.street == street }) {
            var lines: [JSONValue] = []
            if street == .preflop {
                lines.append(.string("\(who(0)) posts the 0.5 bb small blind"))
                lines.append(.string("\(who(1)) posts the 1 bb big blind"))
            }
            var potBefore = street == .preflop ? s.config.smallBlind + s.config.bigBlind : nil as Int?
            for a in s.actions where a.street == street {
                if potBefore == nil { potBefore = a.potAfter - a.amount }
                let pb = potBefore ?? 0
                let v: String
                switch a.kind {
                case .fold: v = "folds"
                case .check: v = "checks"
                case .call: v = "calls \(Chips.text(a.amount)) bb"
                case .bet: v = "bets \(Chips.text(a.to)) bb (\(Int((Double(a.amount) / Double(max(1, pb)) * 100).rounded()))% of the \(Chips.text(pb)) bb pot)"
                case .raise: v = "raises to \(Chips.text(a.to)) bb"
                }
                lines.append(.string("\(who(a.seat)) \(v)\(a.allIn ? " and is all-in" : "")"))
                potBefore = a.potAfter
            }
            if lines.isEmpty { lines.append("no action yet") }
            out[street.name.lowercased()] = .array(lines)
        }
        return .object(out)
    }

    /// One sentence on what the hero is facing right now.
    static func situation(_ ctx: DecisionContext) -> String {
        let s = ctx.state, me = ctx.seat
        let street = s.street.name.lowercased()
        let mine = s.actions.filter { $0.street == s.street }
        guard let last = mine.last(where: { $0.seat != me }) else {
            if s.street == .preflop { return "Preflop, first to act on the button: the hero can fold, limp (call 0.5 bb) or open-raise." }
            return "First to act on the \(street): the hero can check or bet."
        }
        switch last.kind {
        case .check: return "The opponent checked to the hero on the \(street): the hero can check behind or bet."
        case .call:
            if s.street == .preflop && last.to == s.config.bigBlind { return "The opponent limped (called 0.5 bb) preflop: the hero in the big blind can check or raise." }
            return "The opponent called on the \(street): the hero can check or bet."
        case .bet, .raise:
            let toCall = ctx.legal?.toCall ?? 0
            let raises = mine.filter { $0.kind == .raise || $0.kind == .bet }.count
            let label = s.street == .preflop ? ["open-raised", "3-bet", "4-bet", "5-bet"][min(3, max(0, raises - 1))] : (last.kind == .bet ? "bet" : "raised")
            return "The opponent \(label) to \(Chips.text(last.to)) bb on the \(street)\(last.allIn ? " and is all-in" : ""): the hero faces \(Chips.text(toCall)) bb to call."
        case .fold: return "The opponent folded."
        }
    }
}
