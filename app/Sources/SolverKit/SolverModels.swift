import Foundation

// MARK: - Configuration

public struct SizeSpec: Codable, Hashable, Sendable {
    /// Comma separated pot percentages, "a" for all-in. E.g. "33, 75, a".
    public var bet: String
    /// Raise sizes as a percentage of the pot after calling.
    public var raise: String

    public init(bet: String = "", raise: String = "") {
        self.bet = bet
        self.raise = raise
    }
}

public struct StreetSizes: Codable, Hashable, Sendable {
    public var oop: SizeSpec
    public var ip: SizeSpec

    public init(oop: SizeSpec = .init(), ip: SizeSpec = .init()) {
        self.oop = oop
        self.ip = ip
    }

    public static func same(_ s: SizeSpec) -> StreetSizes { StreetSizes(oop: s, ip: s) }
}

public struct BetSizes: Codable, Hashable, Sendable {
    public var flop: StreetSizes
    public var turn: StreetSizes
    public var river: StreetSizes

    public init(flop: StreetSizes = .init(), turn: StreetSizes = .init(), river: StreetSizes = .init()) {
        self.flop = flop
        self.turn = turn
        self.river = river
    }

    /// One bet size per street plus a single raise: fast and usually close to richer trees.
    public static let standard = BetSizes(
        flop: .init(oop: .init(bet: "33", raise: "50"), ip: .init(bet: "33", raise: "50")),
        turn: .same(.init(bet: "75", raise: "50")),
        river: .same(.init(bet: "75", raise: "50"))
    )

    public static let detailed = BetSizes(
        flop: .init(oop: .init(bet: "33", raise: "60"), ip: .init(bet: "33, 75", raise: "60")),
        turn: .same(.init(bet: "66, 125", raise: "60")),
        river: .same(.init(bet: "50, 100", raise: "60"))
    )
}

public struct SolverConfig: Codable, Hashable, Sendable {
    public var board: String
    public var rangeOOP: String
    public var rangeIP: String
    public var startingPot: Double
    public var effectiveStack: Double
    public var betSizes: BetSizes
    /// A bet committing at least this fraction of the remaining stack becomes all-in.
    public var allinThreshold: Double
    public var addAllin: Bool
    public var raiseLimit: Int
    /// 0 = all cores.
    public var threads: Int
    /// 0 = unlimited.
    public var maxMemoryBytes: UInt64

    public init(board: String, rangeOOP: String, rangeIP: String, startingPot: Double, effectiveStack: Double,
                betSizes: BetSizes = .standard, allinThreshold: Double = 0.67, addAllin: Bool = false,
                raiseLimit: Int = 2, threads: Int = 0, maxMemoryBytes: UInt64 = 0) {
        self.board = board
        self.rangeOOP = rangeOOP
        self.rangeIP = rangeIP
        self.startingPot = startingPot
        self.effectiveStack = effectiveStack
        self.betSizes = betSizes
        self.allinThreshold = allinThreshold
        self.addAllin = addAllin
        self.raiseLimit = raiseLimit
        self.threads = threads
        self.maxMemoryBytes = maxMemoryBytes
    }

    enum CodingKeys: String, CodingKey {
        case board
        case rangeOOP = "range_oop"
        case rangeIP = "range_ip"
        case startingPot = "starting_pot"
        case effectiveStack = "effective_stack"
        case betSizes = "bet_sizes"
        case allinThreshold = "allin_threshold"
        case addAllin = "add_allin"
        case raiseLimit = "raise_limit"
        case threads
        case maxMemoryBytes = "max_memory_bytes"
    }
}

// MARK: - Results

public struct TreeStats: Codable, Hashable, Sendable {
    public var actionNodes: UInt64
    public var chanceNodes: UInt64
    public var terminalNodes: UInt64
    public var floats: UInt64

    enum CodingKeys: String, CodingKey {
        case actionNodes = "action_nodes"
        case chanceNodes = "chance_nodes"
        case terminalNodes = "terminal_nodes"
        case floats
    }
}

public struct TreeEstimate: Codable, Hashable, Sendable {
    public var stats: TreeStats
    public var memoryBytes: UInt64
    /// Combos per player after removing board conflicts: [OOP, IP].
    public var hands: [Int]

    enum CodingKeys: String, CodingKey {
        case stats
        case memoryBytes = "memory_bytes"
        case hands
    }
}

public struct SolveProgress: Codable, Hashable, Sendable {
    public var iteration: UInt32
    /// Percent of the starting pot.
    public var exploitability: Float
    /// Seconds spent iterating.
    public var elapsed: Double
}

public enum ActionKind: String, Codable, Sendable {
    case fold, check, call, bet, raise, allin

    public var isAggressive: Bool { self == .bet || self == .raise || self == .allin }
}

public struct ActionInfo: Codable, Hashable, Sendable {
    public var label: String
    public var kind: ActionKind
    /// Chips added by this action.
    public var amount: Float
    /// Street contribution after the action.
    public var to: Float
    /// Bet size relative to the pot (0 for passive actions).
    public var potFraction: Float

    enum CodingKeys: String, CodingKey {
        case label, kind, amount, to
        case potFraction = "pot_fraction"
    }
}

public struct HandInfo: Codable, Hashable, Sendable {
    public var combo: String
    /// Weight in the starting range.
    public var weight: Float
    /// Starting weight times the probability of reaching this node.
    public var reach: Float
    /// Average strategy (one entry per action) when this player is to act.
    public var strategy: [Float]
    /// EV of each action for this hand when this player is to act.
    public var actionEvs: [Float]
    /// Expected chips won from this node on (share of the pot minus future investment).
    public var ev: Float
    public var equity: Float

    enum CodingKeys: String, CodingKey {
        case combo, weight, reach, strategy, ev, equity
        case actionEvs = "action_evs"
    }
}

public struct PlayerView: Codable, Hashable, Sendable {
    public var combos: Float
    public var hands: [HandInfo]
}

public struct NodeInfo: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case action, chance, terminal }

    public var kind: Kind
    public var street: String
    public var board: [String]
    public var pot: Float
    public var startingPot: Float
    public var contrib: [Float]
    public var stacks: [Float]
    /// 0 = OOP, 1 = IP; nil at chance/terminal nodes.
    public var player: Int?
    public var actions: [ActionInfo]
    public var chanceCards: [String]
    public var terminal: String?
    public var history: [String]
    /// [OOP, IP]
    public var players: [PlayerView]
    public var iteration: UInt32
    public var exploitability: Float

    enum CodingKeys: String, CodingKey {
        case kind, street, board, pot, contrib, stacks, player, actions, terminal, history, players, iteration, exploitability
        case startingPot = "starting_pot"
        case chanceCards = "chance_cards"
    }

    /// Range-weighted frequency of each action for the acting player.
    public var actionFrequencies: [Float] {
        guard let p = player else { return [] }
        let hands = players[p].hands
        let total = hands.reduce(Float(0)) { $0 + $1.reach }
        guard total > 0 else { return actions.map { _ in 0 } }
        return actions.indices.map { i in hands.reduce(Float(0)) { $0 + $1.reach * ($1.strategy.count > i ? $1.strategy[i] : 0) } / total }
    }

    /// Reach-weighted EV of a player's range at this node.
    public func rangeEV(_ p: Int) -> Float {
        let hands = players[p].hands
        let total = hands.reduce(Float(0)) { $0 + $1.reach }
        guard total > 0 else { return 0 }
        return hands.reduce(Float(0)) { $0 + $1.reach * $1.ev } / total
    }

    public func rangeEquity(_ p: Int) -> Float {
        let hands = players[p].hands
        let total = hands.reduce(Float(0)) { $0 + $1.reach }
        guard total > 0 else { return 0 }
        return hands.reduce(Float(0)) { $0 + $1.reach * $1.equity } / total
    }
}

/// One step down the game tree: take an action, or deal a card at a chance node.
public enum PathStep: Hashable, Sendable, Codable {
    case action(Int)
    case card(String)

    var json: Any {
        switch self {
        case .action(let i): return i
        case .card(let c): return c
        }
    }
}
