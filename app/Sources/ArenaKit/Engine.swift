import Foundation
import SolverKit

// MARK: - Chips

/// Amounts are integer chips; 1 big blind = 100 chips (so 0.01 bb resolution).
public enum Chips {
    public static let perBB = 100

    public static func bb(_ chips: Int) -> Double { Double(chips) / Double(perBB) }
    public static func from(bb: Double) -> Int { Int((bb * Double(perBB)).rounded()) }

    /// "2.5", "100", "0.33" — trailing zeros trimmed.
    public static func text(_ chips: Int) -> String {
        let sign = chips < 0 ? "-" : ""
        let c = abs(chips)
        if c % perBB == 0 { return "\(sign)\(c / perBB)" }
        if c % 10 == 0 { return sign + String(format: "%.1f", Double(c) / 100) }
        return sign + String(format: "%.2f", Double(c) / 100)
    }
}

// MARK: - Deterministic randomness

/// SplitMix64: tiny, fast and stable across platforms / Swift versions.
public struct SeededRNG: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed ^ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform double in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// Uniform integer in 0..<n.
    public mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }

    /// Mixes several values into one well-distributed seed.
    public static func mix(_ parts: UInt64...) -> UInt64 {
        var r = SeededRNG(seed: 0x51_7C_C1_B7_27_22_0A_95)
        var acc: UInt64 = 0
        for p in parts {
            r = SeededRNG(seed: acc ^ p &* 0x9E37_79B9_7F4A_7C15)
            acc = r.next()
        }
        return acc
    }
}

public enum Deck {
    /// Cards for one deal: hole cards by seat (seat 0 = button) and a five-card runout.
    public struct DealCards: Hashable, Sendable {
        public var hole: [[Card]]
        public var runout: [Card]
    }

    public static func shuffled(seed: UInt64) -> [Card] {
        var rng = SeededRNG(seed: seed)
        var cards = Card.deck
        for i in stride(from: cards.count - 1, to: 0, by: -1) {
            cards.swapAt(i, rng.below(i + 1))
        }
        return cards
    }

    /// Deterministic deal `index` of a match with `seed`.
    public static func deal(seed: UInt64, index: Int) -> DealCards {
        let d = shuffled(seed: SeededRNG.mix(seed, UInt64(index), 0xDEA1))
        return DealCards(hole: [[d[0], d[2]], [d[1], d[3]]], runout: Array(d[4..<9]))
    }
}

// MARK: - Streets & actions

public enum Street: Int, Codable, Sendable, CaseIterable, Comparable {
    case preflop, flop, turn, river

    public var name: String { ["Preflop", "Flop", "Turn", "River"][rawValue] }
    public var boardCount: Int { [0, 3, 4, 5][rawValue] }
    public static func < (a: Street, b: Street) -> Bool { a.rawValue < b.rawValue }
}

public struct ArenaAction: Codable, Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable { case fold, check, call, bet, raise }

    public var kind: Kind
    /// For bet/raise: the player's total contribution on this street after acting. Ignored otherwise.
    public var to: Int

    public init(_ kind: Kind, to: Int = 0) {
        self.kind = kind
        self.to = to
    }

    public static let fold = ArenaAction(.fold)
    public static let check = ArenaAction(.check)
    public static let call = ArenaAction(.call)
    public static func bet(_ to: Int) -> ArenaAction { ArenaAction(.bet, to: to) }
    public static func raise(_ to: Int) -> ArenaAction { ArenaAction(.raise, to: to) }

    public var isAggressive: Bool { kind == .bet || kind == .raise }

    public var description: String {
        isAggressive ? "\(kind.rawValue) to \(Chips.text(to))" : kind.rawValue
    }
}

/// Metadata about how a decision was produced (LLM reasoning, cost, errors...).
public struct DecisionMeta: Codable, Hashable, Sendable {
    /// Short reasoning shown in the UI (model text before the JSON, or a bot's rationale).
    public var reasoning: String?
    /// Provider-exposed hidden reasoning, if any.
    public var thinking: String?
    /// Raw model responses (one per attempt).
    public var raw: [String]
    /// 1-based menu choice as returned by the player.
    public var menuChoice: Int?
    public var latency: Double
    public var promptTokens: Int
    public var completionTokens: Int
    public var reasoningTokens: Int
    public var cost: Double
    /// Parse failures / API errors encountered while producing this decision.
    public var errors: Int
    /// True when the action was replaced by the check/fold default.
    public var fallback: Bool
    public var errorMessage: String?
    /// Decision-model players: the probability vector over the action menu and the state sent.
    public var decision: DecisionTrace?

    public init(reasoning: String? = nil, thinking: String? = nil, raw: [String] = [], menuChoice: Int? = nil, latency: Double = 0,
                promptTokens: Int = 0, completionTokens: Int = 0, reasoningTokens: Int = 0, cost: Double = 0,
                errors: Int = 0, fallback: Bool = false, errorMessage: String? = nil, decision: DecisionTrace? = nil) {
        self.decision = decision
        self.reasoning = reasoning
        self.thinking = thinking
        self.raw = raw
        self.menuChoice = menuChoice
        self.latency = latency
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.reasoningTokens = reasoningTokens
        self.cost = cost
        self.errors = errors
        self.fallback = fallback
        self.errorMessage = errorMessage
    }
}

/// One action as it happened in a hand.
public struct ActionRecord: Codable, Hashable, Sendable {
    public var seat: Int
    public var street: Street
    public var kind: ArenaAction.Kind
    /// Chips added to the pot by this action.
    public var amount: Int
    /// Street contribution of the actor after the action.
    public var to: Int
    public var allIn: Bool
    /// Total pot after the action.
    public var potAfter: Int
    public var meta: DecisionMeta?

    public var action: ArenaAction { ArenaAction(kind, to: to) }
}

public struct LegalActions: Hashable, Sendable {
    public var seat: Int
    /// Chips needed to call (already capped by the stack).
    public var toCall: Int
    public var canFold: Bool
    public var canCheck: Bool
    public var canCall: Bool
    public var canRaise: Bool
    /// Smallest legal raise-to (or the all-in amount if smaller).
    public var minTo: Int
    /// All-in raise-to.
    public var maxTo: Int
    /// Largest street contribution so far.
    public var currentBet: Int
    /// True when there is no bet yet on this street (aggressive action is a bet).
    public var isBet: Bool
    public var callIsAllIn: Bool
}

public struct EngineError: LocalizedError, Sendable {
    public var message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

public struct HandConfig: Codable, Hashable, Sendable {
    public var smallBlind: Int
    public var bigBlind: Int
    /// Starting stacks by seat (seat 0 = button / small blind).
    public var stacks: [Int]

    public init(smallBlind: Int = 50, bigBlind: Int = 100, stacks: [Int] = [10_000, 10_000]) {
        self.smallBlind = smallBlind
        self.bigBlind = bigBlind
        self.stacks = stacks
    }

    public static let standard = HandConfig()
}

public struct HandResult: Codable, Hashable, Sendable {
    /// Net chips won by seat.
    public var net: [Int]
    public var showdown: Bool
    /// Seats that won (two seats = split pot).
    public var winners: [Int]
    /// Pot awarded (after any uncalled bet is returned).
    public var pot: Int
    public var uncalledSeat: Int?
    public var uncalledAmount: Int
    /// Hand categories by seat at showdown.
    public var categories: [String]?
    /// Equity by seat when all chips went in before the river (else nil).
    public var allInEquity: [Double]?
    /// Board cards visible when the money went in.
    public var allInBoardCount: Int?
    /// All-in-EV adjusted net chips by seat (equals `net` when there was no all-in).
    public var evNet: [Double]
}

// MARK: - Hand state machine

/// Heads-up no-limit hold'em hand. Seat 0 is the button (small blind): it acts first
/// preflop and last postflop. Blinds are posted on creation.
public struct HandState: Codable, Hashable, Sendable {
    public let config: HandConfig
    public let hole: [[Card]]
    public let runout: [Card]

    public private(set) var street: Street = .preflop
    public private(set) var boardCount = 0
    public private(set) var stacks: [Int]
    public private(set) var streetContrib: [Int] = [0, 0]
    public private(set) var totalContrib: [Int] = [0, 0]
    public private(set) var folded: [Bool] = [false, false]
    public private(set) var acted: [Bool] = [false, false]
    public private(set) var toAct: Int?
    /// Size of the last full bet/raise increment on this street.
    public private(set) var lastRaiseSize: Int
    public private(set) var actions: [ActionRecord] = []
    public private(set) var result: HandResult?
    /// Street on which betting closed with a player all-in and cards still to come.
    public private(set) var allInStreet: Street?

    public init(config: HandConfig = .standard, hole: [[Card]], runout: [Card]) {
        precondition(hole.count == 2 && hole.allSatisfy { $0.count == 2 } && runout.count == 5)
        self.config = config
        self.hole = hole
        self.runout = runout
        stacks = config.stacks
        lastRaiseSize = config.bigBlind
        post(seat: 0, config.smallBlind)
        post(seat: 1, config.bigBlind)
        toAct = 0
        // Degenerate: a blind put someone all-in.
        if stacks[0] == 0 || stacks[1] == 0 { advance(after: 1) }
    }

    public init(cards: Deck.DealCards, config: HandConfig = .standard) {
        self.init(config: config, hole: cards.hole, runout: cards.runout)
    }

    private mutating func post(seat: Int, _ amount: Int) {
        let a = min(amount, stacks[seat])
        stacks[seat] -= a
        streetContrib[seat] += a
        totalContrib[seat] += a
    }

    public var isComplete: Bool { result != nil }
    public var board: [Card] { Array(runout.prefix(boardCount)) }
    public var pot: Int { totalContrib[0] + totalContrib[1] }
    public var currentBet: Int { max(streetContrib[0], streetContrib[1]) }

    public func legalActions() -> LegalActions? {
        guard let s = toAct, result == nil else { return nil }
        let o = 1 - s
        let cur = currentBet
        let owe = cur - streetContrib[s]
        let toCall = min(owe, stacks[s])
        let maxTo = streetContrib[s] + stacks[s]
        // Heads-up: an all-in opponent can never be raised; otherwise the action is always open
        // (an incomplete raise is necessarily an all-in).
        let canRaise = stacks[s] > owe && stacks[o] > 0 && !folded[o]
        let minTo = min(maxTo, cur + max(lastRaiseSize, config.bigBlind))
        return LegalActions(seat: s, toCall: toCall, canFold: owe > 0, canCheck: owe == 0, canCall: owe > 0,
                            canRaise: canRaise, minTo: minTo, maxTo: maxTo, currentBet: cur, isBet: cur == 0,
                            callIsAllIn: owe > 0 && toCall == stacks[s])
    }

    public func isLegal(_ a: ArenaAction) -> Bool {
        guard let l = legalActions() else { return false }
        switch a.kind {
        case .fold: return l.canFold
        case .check: return l.canCheck
        case .call: return l.canCall
        case .bet, .raise:
            return l.canRaise && a.to <= l.maxTo && (a.to >= l.minTo || a.to == l.maxTo) && a.to > l.currentBet
        }
    }

    /// Applies an action for the player to act. Throws on illegal actions.
    public mutating func apply(_ a: ArenaAction, meta: DecisionMeta? = nil) throws {
        guard let s = toAct, let l = legalActions() else { throw EngineError("hand is not awaiting an action") }
        guard isLegal(a) else { throw EngineError("illegal action \(a) for seat \(s)") }
        var kind = a.kind
        var paid = 0
        switch a.kind {
        case .fold:
            folded[s] = true
        case .check:
            break
        case .call:
            paid = l.toCall
        case .bet, .raise:
            kind = l.isBet ? .bet : .raise
            paid = a.to - streetContrib[s]
            let increment = a.to - l.currentBet
            if increment >= lastRaiseSize { lastRaiseSize = increment }
        }
        stacks[s] -= paid
        streetContrib[s] += paid
        totalContrib[s] += paid
        acted[s] = true
        actions.append(ActionRecord(seat: s, street: street, kind: kind, amount: paid, to: streetContrib[s],
                                    allIn: stacks[s] == 0 && kind != .fold && kind != .check, potAfter: pot, meta: meta))
        advance(after: s)
    }

    private func needsAction(_ p: Int) -> Bool {
        !folded[p] && stacks[p] > 0 && (!acted[p] || streetContrib[p] < currentBet)
    }

    private mutating func advance(after s: Int) {
        if folded[s] || folded[1 - s] {
            finish(foldWinner: folded[0] ? 1 : 0)
            return
        }
        if needsAction(1 - s) { toAct = 1 - s; return }
        if needsAction(s) { toAct = s; return }
        closeStreet()
    }

    private mutating func closeStreet() {
        toAct = nil
        let live = (0..<2).filter { !folded[$0] && stacks[$0] > 0 }
        if street == .river {
            showdown()
        } else if live.count < 2 {
            allInStreet = street
            boardCount = 5
            showdown()
        } else {
            street = Street(rawValue: street.rawValue + 1)!
            boardCount = street.boardCount
            streetContrib = [0, 0]
            acted = [false, false]
            lastRaiseSize = 0
            toAct = 1 // big blind acts first postflop
        }
    }

    private mutating func returnUncalled() -> (Int?, Int) {
        let diff = totalContrib[0] - totalContrib[1]
        guard diff != 0 else { return (nil, 0) }
        let seat = diff > 0 ? 0 : 1
        let amt = abs(diff)
        totalContrib[seat] -= amt
        stacks[seat] += amt
        if streetContrib[seat] >= amt { streetContrib[seat] -= amt }
        return (seat, amt)
    }

    private mutating func finish(foldWinner w: Int) {
        toAct = nil
        let (us, ua) = returnUncalled()
        let p = pot
        var net = [-totalContrib[0], -totalContrib[1]]
        net[w] += p
        stacks[w] += p
        result = HandResult(net: net, showdown: false, winners: [w], pot: p, uncalledSeat: us, uncalledAmount: ua,
                            categories: nil, allInEquity: nil, allInBoardCount: nil, evNet: net.map(Double.init))
    }

    private mutating func showdown() {
        toAct = nil
        boardCount = 5
        let (us, ua) = returnUncalled()
        let p = pot
        let values = (try? GTOCore.evaluate([hole[0] + runout, hole[1] + runout])) ?? []
        var winners: [Int] = [0, 1]
        if values.count == 2 {
            if values[0] > values[1] { winners = [0] } else if values[1] > values[0] { winners = [1] }
        }
        var net = [-totalContrib[0], -totalContrib[1]]
        let share = p / winners.count
        for (i, w) in winners.enumerated() {
            // Odd chip (never happens heads-up after the uncalled bet is returned) goes to the big blind.
            let extra = (i == winners.count - 1) ? p - share * winners.count : 0
            net[w] += share + extra
            stacks[w] += share + extra
        }
        result = HandResult(net: net, showdown: true, winners: winners, pot: p, uncalledSeat: us, uncalledAmount: ua,
                            categories: values.count == 2 ? values.map(\.category) : nil, allInEquity: nil,
                            allInBoardCount: allInStreet.map(\.boardCount), evNet: net.map(Double.init))
    }

    /// Fills all-in EV using an equity function (equity of seat 0 given both hands and a board).
    public mutating func computeAllInEV(equity: (_ hero: [Card], _ villain: [Card], _ board: [Card]) -> Double?) {
        guard var r = result, r.showdown, let n = r.allInBoardCount, n < 5,
              let e0 = equity(hole[0], hole[1], Array(runout.prefix(n))) else { return }
        let eq = [e0, 1 - e0]
        r.allInEquity = eq
        r.evNet = (0..<2).map { eq[$0] * Double(r.pot) - Double(totalContrib[$0]) }
        result = r
    }

    /// Default equity function backed by the solver core (Monte-Carlo, deterministic per spot).
    public static func coreEquity(_ hero: [Card], _ villain: [Card], _ board: [Card]) -> Double? {
        try? GTOCore.equity(hand: hero, board: board, range: villain.compactText, samples: 30_000)
    }
}
