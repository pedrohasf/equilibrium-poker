import Foundation
import OpenRouterKit
import SolverKit

/// Builds the `state` + `choice` question sent to OpenRouter System One decision models — the `v2`
/// presentation. Other presentations live in `DecisionVariants` and reuse these pieces.
///
/// Decision models read a state and answer typed questions; they never see the question id and
/// are better with semantic facts than arithmetic, so the state spells out cards, positions,
/// the betting line with sizes as % pot, and derived facts (pot odds, SPR, hero's made hand and
/// draws). Each legal action becomes one self-contained `criteria` entry with a readable key.
/// Bump `version` whenever the state or question wording changes.
public enum DecisionStateBuilder {
    public static let version = 2
    /// Question id (never shown to the model).
    public static let questionId = "action"

    public static let instructions = """
    You are advising the hero, the player whose turn it is, in the heads-up No-Limit Texas Hold'em spot \
    described in the state. Pick the single legal action that maximises the hero's expected value against a \
    strong, balanced, game-theory-optimal (GTO) opponent who cannot see the hero's cards. Weigh the hero's \
    exact hand against the villain's likely range given the betting so far, blockers, pot odds, the \
    stack-to-pot ratio and position. Bet and raise sizes are fixed; choose only among the listed actions.
    """

    // MARK: Keys

    /// Readable, unique option keys in action order: `fold`, `check`, `call`, `bet_75pct_pot`, `raise_to_12_5bb`, `allin`.
    public static func actionKeys(_ actions: [SpotAction]) -> [String] {
        var used: [String: Int] = [:]
        return actions.map { a in
            let base: String
            switch a.kind {
            case .fold: base = "fold"
            case .check: base = "check"
            case .call: base = "call"
            case .bet: base = "bet_\(Int((a.potFraction * 100).rounded()))pct_pot"
            case .raise: base = "raise_to_\(slug(a.to))bb"
            case .allin: base = "allin"
            }
            used[base, default: 0] += 1
            let n = used[base]!
            return n == 1 ? base : "\(base)_\(n)"
        }
    }

    static func slug(_ x: Double) -> String { BB.fmt(x).replacingOccurrences(of: ".", with: "_") }

    /// Action index for a returned key (exact, then case/whitespace-insensitive); nil if unknown.
    public static func actionIndex(forKey key: String, actions: [SpotAction]) -> Int? {
        let keys = actionKeys(actions)
        if let i = keys.firstIndex(of: key) { return i }
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return keys.firstIndex { $0.lowercased() == k }
    }

    // MARK: Question

    public static func criteria(_ d: Decision) -> [String: String] {
        Dictionary(uniqueKeysWithValues: zip(actionKeys(d.actions), d.actions.map { describe($0, d) }))
    }

    public static func question(_ d: Decision) -> DecisionQuestion {
        .choice(instructions: instructions, criteria: criteria(d))
    }

    public static func questions(_ d: Decision) -> [String: DecisionQuestion] { [questionId: question(d)] }

    /// Self-contained description of one legal action (what it does, its size, and when it is right).
    static func describe(_ a: SpotAction, _ d: Decision) -> String {
        if d.street == .preflop { return describePreflop(a, d) }
        let pot = d.pot
        let heroStack = d.stacks[d.heroSeat]
        let pct = BB.pct(a.potFraction)
        let river = d.street == .river
        switch a.kind {
        case .fold:
            return "Fold: the hero gives up the hand, puts in no more chips and forfeits the \(BB.fmt(pot)) bb pot. "
                + "Right when the hero's hand wins too rarely against the villain's betting range to justify paying "
                + "\(BB.fmt(d.toCall)) bb (it needs \(BB.pct(potOdds(d))) equity)."
        case .check:
            let next: String
            if d.heroIsIP {
                next = river ? "The hand goes straight to showdown." : "The next board card is dealt without further betting."
            } else {
                next = "The villain then acts and may check back or bet."
            }
            return "Check: the hero puts no chips in. \(next) Right when the hero gains more by keeping the pot "
                + "\(BB.fmt(pot)) bb (controlling the pot, inducing bluffs, or realising equity for free) than by betting."
        case .call:
            let after = river ? "The hand then goes to showdown." : "The next board card is then dealt."
            return "Call \(BB.fmt(a.amount)) bb: the hero matches the villain's bet, making the pot \(BB.fmt(pot + a.amount)) bb. "
                + "The hero needs at least \(BB.pct(potOdds(d))) equity against the villain's betting range to break even. \(after) "
                + "Right when the hero beats enough of the villain's bluffs and thin value bets, but raising would not earn more."
        case .bet:
            return "Bet \(BB.fmt(a.amount)) bb, which is \(pct) of the \(BB.fmt(pot)) bb pot. The pot becomes \(BB.fmt(pot + a.amount)) bb "
                + "and the hero keeps \(BB.fmt(max(0, heroStack - a.amount))) bb behind; the villain may fold, call or raise. "
                + "Right for value with hands that worse hands will call, or as a bluff or semi-bluff with hands that profit when the villain folds. "
                + "\(a.potFraction < 0.5 ? "A small size keeps the villain's weaker hands in." : a.potFraction > 1.0 ? "An overbet is a polarised size: very strong hands or bluffs." : "A medium-to-large size pressures the villain's medium-strength hands.")"
        case .raise:
            return "Raise to \(BB.fmt(a.to)) bb: the hero puts in \(BB.fmt(a.amount)) bb (a raise of \(pct) of the pot after calling), making the pot \(BB.fmt(pot + a.amount)) bb "
                + "and leaving \(BB.fmt(max(0, heroStack - a.amount))) bb behind; the villain must call \(BB.fmt(max(0, a.amount - d.toCall))) bb more, fold, or re-raise. "
                + "Right with hands strong enough to get called by worse, or as a bluff with hands that block the villain's strongest holdings and do poorly when just calling."
        case .allin:
            return "All-in for \(BB.fmt(a.amount)) bb (\(d.facingBet ? "a raise of \(pct) of the pot after calling" : "\(pct) of the pot")): the hero commits the whole remaining stack, making the pot \(BB.fmt(pot + a.amount)) bb; "
                + "the villain can only call or fold. Right with the very strongest hands, or as a bluff when the villain folds often enough."
        }
    }

    // MARK: State

    /// Chips to call / (pot after calling).
    public static func potOdds(_ d: Decision) -> Double { d.toCall > 0 ? d.toCall / (d.pot + d.toCall) : 0 }

    public static func effectiveStack(_ d: Decision) -> Double { min(d.stacks[0], d.stacks[1]) }

    /// Stack-to-pot ratio: effective stack behind / current pot.
    public static func spr(_ d: Decision) -> Double { effectiveStack(d) / max(d.pot, 1e-9) }

    static func num(_ x: Double, _ places: Double = 100) -> JSONValue { .number((x * places).rounded() / places) }

    public static func state(_ d: Decision) -> JSONValue {
        if d.street == .preflop { return preflopState(d) }
        let hero = d.heroPosition, villain = d.villainPosition
        let names = [d.positions[0] + (d.heroSeat == 0 ? " (hero)" : " (villain)"),
                     d.positions[1] + (d.heroSeat == 1 ? " (hero)" : " (villain)")]
        let heroCards = Card.parseList(d.heroCards) ?? []
        let board = d.boardCards

        // Betting so far, street by street.
        var streets: [JSONValue] = []
        for street in Street.historyStreets(upTo: d.street) {
            let cards: [String]
            switch street {
            case .preflop: cards = []
            case .flop: cards = Array(d.board.prefix(3))
            case .turn: cards = d.board.count > 3 ? [d.board[3]] : []
            case .river: cards = d.board.count > 4 ? [d.board[4]] : []
            }
            let entries = d.history.filter { $0.street == street && $0.action != nil }
            let potStart = street <= .flop ? d.flopPot
                : (d.history.first { $0.street == street }?.potBefore ?? entries.first?.potBefore ?? d.pot)
            var acts = entries.map { JSONValue.string($0.text(names: names)) }
            if street == d.street { acts.append(.string("\(names[d.heroSeat]) to act")) }
            streets.append([
                "street": .string(street.rawValue),
                "new_cards": .string(cards.joined(separator: " ")),
                "pot_at_start_bb": num(potStart),
                "actions": .array(acts),
            ])
        }

        var spot: [String: JSONValue] = [
            "street": .string(d.street.rawValue),
            "pot_bb": num(d.pot),
            "hero_stack_bb": num(d.stacks[d.heroSeat]),
            "villain_stack_bb": num(d.stacks[1 - d.heroSeat]),
            "effective_stack_bb": num(effectiveStack(d)),
            "stack_to_pot_ratio": num(spr(d)),
            "facing_bet": .bool(d.facingBet),
            "amount_to_call_bb": num(d.toCall),
        ]
        if d.facingBet {
            spot["pot_odds"] = .string("call \(BB.fmt(d.toCall)) bb to win a \(BB.fmt(d.pot)) bb pot")
            spot["equity_needed_to_call_pct"] = num(potOdds(d) * 100, 10)
        }
        spot["summary"] = .string(d.facingBet
            ? "\(villain) bet; \(hero) (hero) must call \(BB.fmt(d.toCall)) bb, fold or raise. Pot \(BB.fmt(d.pot)) bb."
            : "\(hero) (hero) is first to act or was checked to on the \(d.street.rawValue). Pot \(BB.fmt(d.pot)) bb.")

        let keys = actionKeys(d.actions)
        let legal: [JSONValue] = d.actions.enumerated().map { i, a in
            var o: [String: JSONValue] = ["key": .string(keys[i]), "label": .string(a.detailedLabel), "type": .string(a.kind.rawValue)]
            if a.kind != .fold && a.kind != .check {
                o["chips_added_bb"] = num(a.amount)
                o["pot_after_bb"] = num(d.pot + a.amount)
            }
            if a.kind.isAggressive { o["size_pct_pot"] = .number((a.potFraction * 100).rounded()) }
            return .object(o)
        }

        var heroObj: [String: JSONValue] = [
            "position": .string(hero),
            "in_position": .bool(d.heroIsIP),
            "acts": .string(d.heroIsIP ? "last on each street (in position)" : "first on each street (out of position)"),
            "hole_cards": .string(heroCards.map(\.description).joined(separator: " ")),
            "hole_cards_spelled": .string(heroCards.map(spell).joined(separator: " and ")),
            "stack_bb": num(d.stacks[d.heroSeat]),
        ]
        let facts = HandFacts(hole: heroCards, board: board, street: d.street)
        heroObj["made_hand"] = .string(facts.madeHand)
        if d.street != .river { heroObj["draws"] = .array(facts.draws.map { .string($0) }) }

        return [
            "game": [
                "variant": "No-Limit Texas Hold'em, heads-up postflop",
                "setup": .string(setupText(d)),
                "units": "all amounts in big blinds (bb); pot includes every chip committed, including a bet being faced",
                "card_notation": "rank + suit: A K Q J T(10) 9-2; s spades, h hearts, d diamonds, c clubs",
            ],
            "preflop": .string(d.preflopSummary),
            "hero": .object(heroObj),
            "villain": [
                "position": .string(villain),
                "in_position": .bool(!d.heroIsIP),
                "stack_bb": num(d.stacks[1 - d.heroSeat]),
                "hole_cards": "unknown",
                "style": "strong, balanced (GTO) player",
            ],
            "board": [
                "cards": .string(d.board.joined(separator: " ")),
                "cards_spelled": .string(board.map(spell).joined(separator: ", ")),
                "texture": .string(HandFacts.texture(board)),
            ],
            "betting_by_street": .array(streets),
            "spot": .object(spot),
            "legal_actions": .array(legal),
        ]
    }

    /// Table/format description: cash "6-max … 100 bb", tournaments/spins from `GameFormat` (chip EV).
    static func setupText(_ d: Decision) -> String {
        let f = d.format
        if f == .cash { return "6-max positions, everyone else folded preflop; 100 bb starting stacks" }
        return "\(f.title): \(f.summary) Everyone else folded preflop; stacks as shown."
    }

    // MARK: Preflop

    /// "pocket aces", "ace-king suited", "seven-two offsuit".
    public static func handClassText(_ cards: [Card]) -> String {
        guard cards.count == 2 else { return "unknown" }
        let (hi, lo) = cards[0].rank >= cards[1].rank ? (cards[0], cards[1]) : (cards[1], cards[0])
        if hi.rank == lo.rank { return "pocket \(HandFacts.plural[hi.rank.rawValue])" }
        return "\(rankNames[hi.rank.rawValue].lowercased())-\(rankNames[lo.rank.rawValue].lowercased()) \(hi.suit == lo.suit ? "suited" : "offsuit")"
    }

    /// "AKs", "72o", "TT".
    public static func handClassCode(_ cards: [Card]) -> String {
        guard cards.count == 2 else { return "" }
        let (hi, lo) = cards[0].rank >= cards[1].rank ? (cards[0], cards[1]) : (cards[1], cards[0])
        return "\(hi.rank.char)\(lo.rank.char)" + (hi.rank == lo.rank ? "" : hi.suit == lo.suit ? "s" : "o")
    }

    static func describePreflop(_ a: SpotAction, _ d: Decision) -> String {
        let heroStack = d.stacks[d.heroSeat]
        switch a.kind {
        case .fold:
            return "Fold: the hero gives up the hand and the chips already posted; the villain wins the \(BB.fmt(d.pot)) bb pot."
                + (d.toCall > 0 ? " Right with hands too weak to continue for \(BB.fmt(d.toCall)) bb (calling needs about \(BB.pct(potOdds(d))) equity before position effects)." : "")
        case .check:
            return "Check: the BB takes the free flop after the SB limped; the pot stays \(BB.fmt(d.pot)) bb. Right with hands that do not gain from raising."
        case .call:
            if a.name?.hasPrefix("Limp") == true {
                return "Limp: complete the small blind (0.5 bb more) to see a flop in a \(BB.fmt(d.pot + a.amount)) bb pot; the BB may check or raise. "
                    + "Right with hands that play well in small pots but gain little from raising."
            }
            let allIn = a.amount >= heroStack - 1e-6
            return "Call \(BB.fmt(a.amount)) bb: the hero matches the villain's raise, making the pot \(BB.fmt(d.pot + a.amount)) bb. It needs at least "
                + "\(BB.pct(potOdds(d))) equity against the villain's range to break even" + (allIn
                    ? "; the hero is all-in and the hand goes to showdown."
                    : " (less in position, more out of position, since equity is not fully realised); the flop is dealt next.")
        case .bet, .raise:
            return "Raise to \(BB.fmt(a.to)) bb: the hero puts in \(BB.fmt(a.amount)) bb more (pot becomes \(BB.fmt(d.pot + a.amount)) bb, "
                + "\(BB.fmt(max(0, heroStack - a.amount))) bb behind); the villain may fold, call or re-raise. Right with hands that are ahead of the "
                + "villain's continuing range, or as a bluff with hands that block strong holdings and play poorly when called."
        case .allin:
            return "All-in for \(BB.fmt(a.to)) bb total (\(BB.fmt(a.amount)) bb more): the villain can only call or fold. Right with strong hands, "
                + "or with hands that profit from the villain's folds plus their equity when called."
        }
    }

    /// Preflop state: no board; blinds, ante, seats (the SB is the button), preflop history and pot odds.
    static func preflopState(_ d: Decision) -> JSONValue {
        let names = [d.positions[0] + (d.heroSeat == 0 ? " (hero)" : " (villain)"),
                     d.positions[1] + (d.heroSeat == 1 ? " (hero)" : " (villain)")]
        let hero = Card.parseList(d.heroCards) ?? []
        var acts = d.history.filter { $0.action != nil }.map { JSONValue.string($0.text(names: names)) }
        acts.append(.string("\(names[d.heroSeat]) to act"))
        let ante = d.ante ?? 0
        var spot: [String: JSONValue] = [
            "street": "preflop",
            "pot_bb": num(d.pot),
            "hero_stack_bb": num(d.stacks[d.heroSeat]),
            "villain_stack_bb": num(d.stacks[1 - d.heroSeat]),
            "effective_stack_bb": num(effectiveStack(d)),
            "facing_raise": .bool(d.history.contains { $0.seat == 1 - d.heroSeat && ($0.action?.kind.isAggressive ?? false) }),
            "amount_to_call_bb": num(d.toCall),
        ]
        if d.facingBet {
            spot["pot_odds"] = .string("call \(BB.fmt(d.toCall)) bb to win a \(BB.fmt(d.pot)) bb pot")
            spot["equity_needed_to_call_pct"] = num(potOdds(d) * 100, 10)
        }
        let keys = actionKeys(d.actions)
        let legal: [JSONValue] = d.actions.enumerated().map { i, a in
            var o: [String: JSONValue] = ["key": .string(keys[i]), "label": .string(a.label), "type": .string(a.kind.rawValue)]
            if a.kind != .fold && a.kind != .check {
                o["chips_added_bb"] = num(a.amount)
                o["total_bet_bb"] = num(a.to)
                o["pot_after_bb"] = num(d.pot + a.amount)
            }
            return .object(o)
        }
        let heroRole = d.heroSeat == 0 ? "small blind and button: acts first preflop, last (in position) on every later street"
            : "big blind: acts last preflop, first (out of position) on every later street"
        return [
            "game": [
                "variant": "No-Limit Texas Hold'em, heads-up preflop (blind vs blind)",
                "setup": .string(setupText(d)),
                "seats": "SB is the button: acts first preflop, last postflop. BB acts last preflop, first postflop.",
                "blinds": .string("SB 0.5 bb, BB 1 bb" + (ante > 0 ? ", plus a \(BB.fmt(ante)) bb big-blind ante (dead money in the pot)" : ", no ante")),
                "units": "all amounts in big blinds (bb); pot includes the blinds, antes and every chip committed, including a raise being faced",
                "card_notation": "rank + suit: A K Q J T(10) 9-2; s spades, h hearts, d diamonds, c clubs",
            ],
            "preflop": .string(d.preflopSummary),
            "hero": [
                "position": .string(d.heroPosition),
                "role": .string(heroRole),
                "in_position_postflop": .bool(d.heroIsIP),
                "hole_cards": .string(hero.map(\.description).joined(separator: " ")),
                "hole_cards_spelled": .string(hero.map(spell).joined(separator: " and ")),
                "hand": .string(handClassText(hero) + " (\(handClassCode(hero)))"),
                "stack_bb": num(d.stacks[d.heroSeat]),
            ],
            "villain": [
                "position": .string(d.villainPosition),
                "stack_bb": num(d.stacks[1 - d.heroSeat]),
                "hole_cards": "unknown",
                "style": "strong, balanced (GTO) player",
            ],
            "betting": [
                "street": "preflop",
                "pot_at_start_bb": num(d.flopPot),
                "actions": .array(acts),
            ],
            "spot": .object(spot),
            "legal_actions": .array(legal),
        ]
    }

    /// The exact request body (minus auth) sent to `/api/alpha/decisions` for `variant`.
    public static func requestBody(_ d: Decision, model: String = "<decision-model>", variant: DecisionVariant) -> JSONValue {
        variant.requestBody(d, model: model)
    }

    /// The exact request body (minus auth) sent to `/api/alpha/decisions` (v2), for display and the CLI.
    public static func requestBody(_ d: Decision, model: String = "<decision-model>") -> JSONValue {
        let crit = criteria(d).mapValues { JSONValue.string($0) }
        return [
            "model": .string(model),
            "state": state(d),
            "questions": .object([questionId: ["type": "choice", "instructions": .string(instructions), "criteria": .object(crit)]]),
        ]
    }

    /// Approximate billed input tokens (see `DecisionVariant.estimatedInputTokens`).
    public static func estimatedInputTokens(_ d: Decision) -> Int { DecisionVariants.v2.estimatedInputTokens(d) }

    // MARK: Cards

    static let rankNames = ["Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Jack", "Queen", "King", "Ace"]
    static let suitNames = ["clubs", "diamonds", "hearts", "spades"]

    static func spell(_ c: Card) -> String { "\(rankNames[c.rank.rawValue]) of \(suitNames[c.suit.rawValue])" }
}

/// Pre-run cost estimate. Decision models bill input tokens only (output is free).
public enum CostEstimator {
    public struct Estimate: Sendable, Hashable {
        public var promptTokens: Int
        /// nil when the model's input price is unknown.
        public var usd: Double?
    }

    public static func estimate(decisions: [Decision], promptPrice: Double?, variant: DecisionVariant = DecisionVariants.default) -> Estimate {
        let p = decisions.reduce(0) { $0 + variant.estimatedInputTokens($1) }
        return Estimate(promptTokens: p, usd: promptPrice.map { Double(p) * $0 })
    }
}

/// Exact, cheap facts about hero's hand on the board (made hand, draws, texture).
struct HandFacts {
    let madeHand: String
    let draws: [String]

    static let plural = ["twos", "threes", "fours", "fives", "sixes", "sevens", "eights", "nines", "tens", "jacks", "queens", "kings", "aces"]

    init(hole: [Card], board: [Card], street: Street) {
        guard hole.count == 2, board.count >= 3 else { madeHand = "unknown"; draws = []; return }
        let all = hole + board
        let category = (try? GTOCore.evaluate([all]))?.first?.category ?? ""
        let boardRanks = Array(Set(board.map(\.rank))).sorted(by: >)
        let r = DecisionStateBuilder.rankNames
        var made = category.isEmpty ? "unknown" : category.lowercased()
        let holePair = hole[0].rank == hole[1].rank
        let paired = hole.filter { h in board.contains { $0.rank == h.rank } }
        if category == "Pair" {
            if holePair {
                let rk = hole[0].rank
                if rk > boardRanks[0] { made = "overpair (pocket \(Self.plural[rk.rawValue]))" }
                else {
                    let above = boardRanks.filter { $0 > rk }.count
                    made = "pocket pair of \(Self.plural[rk.rawValue]) below \(above) board card rank\(above == 1 ? "" : "s")"
                }
            } else if let p = paired.first {
                let pos = boardRanks.firstIndex(of: p.rank) ?? 0
                let kicker = hole.first { $0 != p }!.rank
                let which = pos == 0 ? "top pair" : pos == 1 ? "second pair" : pos == boardRanks.count - 1 ? "bottom pair" : "third pair"
                made = "\(which) (\(Self.plural[p.rank.rawValue])) with \(r[kicker.rawValue].lowercased()) kicker"
            } else {
                made = "only the pair on the board (\(r[max(hole[0].rank, hole[1].rank).rawValue].lowercased()) high in hand)"
            }
        } else if category == "Trips" {
            let tripRank = Dictionary(grouping: all, by: \.rank).first { $0.value.count == 3 }?.key ?? hole[0].rank
            made = holePair ? "set of \(Self.plural[tripRank.rawValue])" : "trips (\(Self.plural[tripRank.rawValue]))"
        } else if category == "Two pair" {
            let pairs = Dictionary(grouping: all, by: \.rank).filter { $0.value.count >= 2 }.keys.sorted(by: >).prefix(2)
            let parts = pairs.map { rk -> String in
                let inHole = hole.filter { $0.rank == rk }.count
                let how = inHole == 2 ? "hero's pocket pair" : inHole == 1 ? "pairing hero's \(r[rk.rawValue].lowercased())" : "on the board"
                return "\(Self.plural[rk.rawValue]) (\(how))"
            }
            made = "two pair: " + parts.joined(separator: " and ")
        } else if category == "Flush" {
            let suit = Dictionary(grouping: all, by: \.suit).first { $0.value.count >= 5 }?.key
            let mine = hole.filter { $0.suit == suit }.map(\.rank).sorted(by: >)
            if let top = mine.first, let suit {
                let higherMissing = Rank.allCases.filter { $0 > top && !all.contains(Card($0, suit)) }.count
                made = higherMissing == 0 ? "nut flush (hero holds the \(r[top.rawValue].lowercased()) of the suit)"
                    : "\(r[top.rawValue].lowercased())-high flush (\(higherMissing) higher card\(higherMissing == 1 ? "" : "s") of the suit unseen)"
            } else {
                made = "flush entirely on the board (hero holds none of the suit)"
            }
        } else if category == "High card" {
            made = "no pair, \(r[max(hole[0].rank, hole[1].rank).rawValue].lowercased()) high"
        } else if !category.isEmpty {
            // Flag hands that are entirely on the board.
            let boardOnly = board.count == 5 ? (try? GTOCore.evaluate([board]))?.first?.category : nil
            if boardOnly == category && paired.isEmpty && category != "Flush" && category != "Straight" {
                made += " (shared with the board)"
            }
        }
        madeHand = made

        var ds: [String] = []
        if street != .river {
            // Flush draw: four of a suit using at least one hole card, no flush yet.
            if category != "Flush" && category != "Straight flush" {
                for s in Set(hole.map(\.suit)) where all.filter({ $0.suit == s }).count == 4 {
                    let nut = !Rank.allCases.reversed().contains { rk in
                        rk > (hole.filter { $0.suit == s }.map(\.rank).max() ?? .two) && !all.contains(Card(rk, s))
                    }
                    ds.append(nut ? "nut flush draw" : "flush draw")
                }
            }
            // Straight draws: ranks that would complete a straight using a hole card.
            if !["Straight", "Flush", "Full house", "Quads", "Straight flush"].contains(category) {
                let have = Set(all.map { $0.rank.rawValue })
                let boardSet = Set(board.map { $0.rank.rawValue })
                func straight(_ ranks: Set<Int>) -> Bool {
                    var rs = ranks
                    if rs.contains(12) { rs.insert(-1) }
                    return (-1...8).contains { lo in (lo...(lo + 4)).allSatisfy(rs.contains) }
                }
                let outs = (0..<13).filter { !have.contains($0) && straight(have.union([$0])) && !straight(boardSet.union([$0])) }
                if outs.count >= 2 { ds.append("open-ended straight draw (or double gutshot)") }
                else if outs.count == 1 { ds.append("gutshot straight draw") }
            }
        }
        draws = ds
    }

    static func texture(_ board: [Card]) -> String {
        guard board.count >= 3 else { return "" }
        var parts: [String] = []
        let counts = Dictionary(grouping: board, by: \.rank).mapValues(\.count)
        let maxRank = counts.values.max() ?? 1
        parts.append(maxRank >= 3 ? "trips on board" : counts.values.filter { $0 == 2 }.count >= 2 ? "double-paired" : maxRank == 2 ? "paired" : "unpaired")
        let suitMax = Dictionary(grouping: board, by: \.suit).values.map(\.count).max() ?? 1
        if board.count == 3 {
            parts.append(suitMax == 3 ? "monotone" : suitMax == 2 ? "two-tone" : "rainbow")
        } else {
            parts.append(suitMax >= 3 ? "flush possible (\(suitMax) of one suit)" : suitMax == 2 ? "flush draw possible" : "no flush possible")
        }
        var rs = Set(board.map { $0.rank.rawValue })
        if rs.contains(12) { rs.insert(-1) }
        // A straight is possible if some 5-rank window contains ≥ 3 board ranks.
        let straightPossible = (-1...8).contains { lo in (lo...(lo + 4)).filter(rs.contains).count >= 3 }
        parts.append(straightPossible ? "straight possible" : "no straight possible")
        let high = board.map(\.rank).max()!
        parts.append("\(DecisionStateBuilder.rankNames[high.rawValue].lowercased())-high")
        return parts.joined(separator: ", ")
    }
}
