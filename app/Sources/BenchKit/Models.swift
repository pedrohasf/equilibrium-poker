import Foundation
import SolverKit

// MARK: - Streets

public enum Street: String, Codable, CaseIterable, Sendable, Comparable, Identifiable {
    case preflop, flop, turn, river

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    /// Number of board cards on this street.
    public var boardCount: Int { self == .preflop ? 0 : 2 + order }
    public var order: Int { Street.allCases.firstIndex(of: self)! }
    public var isPostflop: Bool { self != .preflop }
    public static let postflop: [Street] = [.flop, .turn, .river]

    /// Streets shown in a decision's betting history: just preflop for preflop decisions, otherwise flop…`s`
    /// (a postflop decision's preflop action is summarised by the scenario).
    public static func historyStreets(upTo s: Street) -> [Street] { s == .preflop ? [.preflop] : postflop.filter { $0 <= s } }

    public init?(boardCount: Int) {
        switch boardCount {
        case 0: self = .preflop
        case 3: self = .flop
        case 4: self = .turn
        case 5: self = .river
        default: return nil
        }
    }

    public static func < (a: Street, b: Street) -> Bool { a.order < b.order }

    /// Parses "river,turn" style lists.
    public static func parseList(_ text: String) -> [Street] {
        text.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Street(rawValue: $0.lowercased()) }
    }
}

// MARK: - Spot description

/// One legal action at a decision, with amounts in big blinds.
public struct SpotAction: Codable, Hashable, Sendable {
    public var kind: ActionKind
    /// Chips added to the pot by this action (bb).
    public var amount: Double
    /// The actor's total contribution on this street after the action (bb).
    public var to: Double
    /// Bet/raise size relative to the pot (0 for passive actions).
    public var potFraction: Double
    /// Solver-provided label for preflop actions ("Limp (call 0.5)", "Raise to 2.5", "All-in 20"); nil postflop.
    public var name: String? = nil

    public init(kind: ActionKind, amount: Double, to: Double, potFraction: Double, name: String? = nil) {
        self.kind = kind
        self.amount = amount
        self.to = to
        self.potFraction = potFraction
        self.name = name
    }

    public init(_ a: ActionInfo) {
        self.init(kind: a.kind, amount: Double(a.amount), to: Double(a.to), potFraction: Double(a.potFraction))
    }

    /// Preflop action: keeps the solver's label.
    public init(preflop a: ActionInfo) {
        self.init(kind: a.kind, amount: Double(a.amount), to: Double(a.to), potFraction: Double(a.potFraction), name: a.label)
    }

    /// Exact label used in prompts and parsing, e.g. "Bet 4.1 bb", "Raise to 12.5 bb".
    public var label: String {
        if let name { return name }
        switch kind {
        case .fold: return "Fold"
        case .check: return "Check"
        case .call: return "Call \(BB.fmt(amount)) bb"
        case .bet: return "Bet \(BB.fmt(amount)) bb"
        case .raise: return "Raise to \(BB.fmt(to)) bb"
        case .allin: return "All-in \(BB.fmt(amount)) bb"
        }
    }

    /// Label plus a size hint, e.g. "Bet 4.1 bb (75% pot)".
    public var detailedLabel: String {
        guard kind.isAggressive, potFraction > 0, name == nil else { return label }
        return "\(label) (\(BB.pct(potFraction)) pot)"
    }

    /// Short tag for compact UI ("X", "B 75%", "C", "F", "R", "AI").
    public var shortLabel: String {
        switch kind {
        case .fold: return "Fold"
        case .check: return "Check"
        case .call: return "Call"
        case .bet: return "Bet \(Int((potFraction * 100).rounded()))%"
        case .raise: return "Raise \(BB.fmt(to))"
        case .allin: return "All-in"
        }
    }

    /// Bridges back to the solver type for shared UI helpers (colours).
    /// (`ActionInfo` has no public memberwise init, so this round-trips through its Codable form.)
    public var actionInfo: ActionInfo {
        let obj: [String: Any] = ["label": label, "kind": kind.rawValue, "amount": amount, "to": to, "pot_fraction": potFraction]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return (try? JSONDecoder().decode(ActionInfo.self, from: data))
            ?? (try! JSONDecoder().decode(ActionInfo.self, from: Data(#"{"label":"?","kind":"check","amount":0,"to":0,"pot_fraction":0}"#.utf8)))
    }
}

/// One line of the hand history shown to players.
public struct HistoryEntry: Codable, Hashable, Sendable {
    public var street: Street
    /// 0 = OOP, 1 = IP; nil for card deals / street headers.
    public var seat: Int?
    public var action: SpotAction?
    /// Pot at the moment of the action (before it), bb.
    public var potBefore: Double
    /// Dealt card, for chance entries.
    public var card: String?
    /// True for the approximated pre-subgame line (not solved).
    public var synthetic: Bool

    public init(street: Street, seat: Int?, action: SpotAction?, potBefore: Double, card: String? = nil, synthetic: Bool = false) {
        self.street = street
        self.seat = seat
        self.action = action
        self.potBefore = potBefore
        self.card = card
        self.synthetic = synthetic
    }

    /// "BTN bets 4.1 bb (75% pot)".
    public func text(names: [String]) -> String {
        if let card { return "\(street.title) card: \(card)" }
        guard let seat, let a = action else { return "" }
        let who = names[seat]
        if street == .preflop {
            switch a.kind {
            case .fold: return "\(who) folds"
            case .check: return "\(who) checks"
            case .call: return a.name?.hasPrefix("Limp") == true ? "\(who) limps (calls 0.5 bb)" : "\(who) calls \(BB.fmt(a.amount)) bb"
            case .bet, .raise: return "\(who) raises to \(BB.fmt(a.to)) bb"
            case .allin: return "\(who) goes all-in (\(BB.fmt(a.to)) bb total)"
            }
        }
        switch a.kind {
        case .fold: return "\(who) folds"
        case .check: return "\(who) checks"
        case .call: return "\(who) calls \(BB.fmt(a.amount)) bb"
        case .bet: return "\(who) bets \(BB.fmt(a.amount)) bb (\(BB.pct(a.potFraction)) pot)"
        case .raise: return "\(who) raises to \(BB.fmt(a.to)) bb (\(BB.pct(a.potFraction)) pot)"
        case .allin: return "\(who) goes all-in for \(BB.fmt(a.amount)) bb"
        }
    }
}

/// A single benchmark question: a concrete hand at a solved decision point.
public struct Decision: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var scenarioId: String
    public var scenarioName: String
    public var preflopSummary: String
    /// [OOP, IP] position names.
    public var positions: [String]
    /// 0 = hero is OOP, 1 = hero is IP.
    public var heroSeat: Int
    public var street: Street
    /// Board cards visible at the decision.
    public var board: [String]
    /// Board when the solved subgame starts (flop/turn/river root).
    public var rootStreet: Street
    public var heroCards: String
    /// Villain's sampled hand (never shown to players; used by the explorer).
    public var villainCards: String
    /// Pot at the start of the flop, bb (from the preflop scenario).
    public var flopPot: Double
    /// Pot at the root of the solved subgame, bb.
    public var subgamePot: Double
    /// Current pot including any bet hero is facing, bb.
    public var pot: Double
    /// Remaining stacks [OOP, IP], bb.
    public var stacks: [Double]
    /// Chips hero must add to call (0 if not facing a bet).
    public var toCall: Double
    /// Full action history from the flop: synthetic prior streets + solved subgame.
    public var history: [HistoryEntry]
    public var actions: [SpotAction]
    /// GTO average strategy of hero's combo.
    public var strategy: [Double]
    /// EV of each action for hero's combo, bb, node-relative.
    public var actionEVs: [Double]
    /// Hero's equity vs villain's range at this node.
    public var equity: Double
    /// Solver exploitability in % of the subgame pot.
    public var exploitability: Double
    /// Index of the generating solve within the suite.
    public var spotIndex: Int
    /// Hands-mode suites: the dealt hand this decision belongs to (every decision of both players
    /// in one hand shares it). nil for spot-mode suites.
    public var handId: String? = nil
    /// Hands mode: 0-based order of this decision within its hand.
    public var handSeq: Int? = nil
    /// `GameFormat` raw value (hands / preflop suites); nil = derive from the scenario (cash).
    public var formatId: String? = nil
    /// Preflop decisions: dead BB ante (bb).
    public var ante: Double? = nil

    public var heroPosition: String { positions[heroSeat] }
    public var villainPosition: String { positions[1 - heroSeat] }
    /// Postflop position. Preflop seats are [SB, BB] and the SB (button) is in position postflop.
    public var heroIsIP: Bool { street == .preflop ? heroSeat == 0 : heroSeat == 1 }
    public var format: GameFormat { formatId.flatMap(GameFormat.init(rawValue:)) ?? Scenarios.named(scenarioId)?.format ?? .cash }
    public var bestEV: Double { actionEVs.max() ?? 0 }
    public var worstEV: Double { actionEVs.min() ?? 0 }
    /// Range of action EVs (bb).
    public var evSpread: Double { bestEV - worstEV }
    public var bestAction: Int { actionEVs.indices.max { actionEVs[$0] < actionEVs[$1] } ?? 0 }
    public var gtoAction: Int { strategy.indices.max { strategy[$0] < strategy[$1] } ?? 0 }
    public var facingBet: Bool { toCall > 0 }
    public var decisionType: DecisionType { facingBet ? .facingBet : .firstToAct }
    /// `evSpread` as a fraction of the pot (hands suites keep trivial spots; filter on this).
    public var evSpreadPot: Double { evSpread / max(pot, 1e-9) }
    /// Clustering key for per-hand statistics: the hand id, or the decision id for spot suites.
    public var clusterId: String { handId ?? id }

    public var heroCardList: [Card] { Card.parseList(heroCards) ?? [] }
    public var boardCards: [Card] { board.compactMap(Card.init) }

    /// EV lost by choosing `index` (bb); invalid choices cost the full spread.
    public func evLoss(_ index: Int?) -> Double {
        guard let i = index, actionEVs.indices.contains(i) else { return evSpread }
        return max(0, bestEV - actionEVs[i])
    }

    /// Compact one-line description for lists and logs.
    public var headline: String {
        "\(street.title) · \(heroPosition) \(facingBet ? "facing \(BB.fmt(toCall)) bb" : "to act") · \(heroCards)"
            + (board.isEmpty ? "" : " on \(board.joined(separator: " "))")
    }

    /// Human-readable street-by-street history, one line per street. `names` defaults to the
    /// positions with " (you)" after hero's.
    public func historyLines(names: [String]? = nil) -> [String] {
        let names = names ?? positions.enumerated().map { $0.offset == heroSeat ? $0.element + " (you)" : $0.element }
        var lines: [String] = []
        for street in Street.historyStreets(upTo: self.street) {
            let boardText: String
            switch street {
            case .preflop: boardText = ""
            case .flop: boardText = board.prefix(3).joined(separator: " ")
            case .turn: boardText = board.count > 3 ? board[3] : ""
            case .river: boardText = board.count > 4 ? board[4] : ""
            }
            let entries = history.filter { $0.street == street && $0.action != nil }
            let potStart = street <= .flop ? flopPot
                : (history.first { $0.street == street }?.potBefore ?? entries.first?.potBefore ?? pot)
            let acts = entries.map { $0.text(names: names) }
            let body = acts.isEmpty ? "(no action yet)" : acts.joined(separator: ", ") + (street == self.street ? "" : ".")
            lines.append("\(street.title)\(boardText.isEmpty ? "" : " " + boardText) (pot \(BB.fmt(potStart)) bb): \(body)")
        }
        return lines
    }
}

public enum DecisionType: String, Codable, CaseIterable, Sendable, Identifiable {
    case firstToAct, facingBet
    public var id: String { rawValue }
    public var title: String { self == .facingBet ? "Facing bet" : "Check / bet" }
}

// MARK: - Suites

public struct SuiteParameters: Codable, Hashable, Sendable {
    public var decisions: Int
    /// Root street of the solved subgames.
    public var streets: [Street]
    /// Empty = all scenarios.
    public var scenarioIds: [String]
    public var seed: UInt64
    /// Skip decisions whose (max − min) action EV is below this fraction of the pot.
    public var minEVSpread: Double
    /// Stop solving at this exploitability (% of pot).
    public var targetExploitability: Double
    public var maxIterations: Int
    /// Upper bound on decisions sampled from one solved subgame.
    public var decisionsPerSolve: Int
    /// Concurrent solves.
    public var concurrency: Int

    /// `spots` (default, legacy) or `hands`. nil in suites saved before modes existed (= spots).
    public var mode: SuiteMode? = nil
    /// Hands mode: number of complete hands to deal.
    public var hands: Int? = nil
    /// Hands mode: hands dealt from each flop solve.
    public var handsPerSolve: Int? = nil
    /// Hands mode: fixed flop tree for every solve. nil = chosen per solve from the scenario's SPR
    /// (`HandsTreeConfig.forSPR`) with `targetExploitability` / `maxIterations`.
    public var handsTree: HandsTreeConfig? = nil
    /// Game format (`GameFormat` raw value) of a hands suite; nil = cash.
    public var format: String? = nil

    public init(decisions: Int = 60, streets: [Street] = [.river, .turn], scenarioIds: [String] = [], seed: UInt64 = 1,
                minEVSpread: Double = 0.02, targetExploitability: Double = 0.4, maxIterations: Int = 1000,
                decisionsPerSolve: Int = 3, concurrency: Int = 2) {
        self.decisions = decisions
        self.streets = streets
        self.scenarioIds = scenarioIds
        self.seed = seed
        self.minEVSpread = minEVSpread
        self.targetExploitability = targetExploitability
        self.maxIterations = maxIterations
        self.decisionsPerSolve = decisionsPerSolve
        self.concurrency = concurrency
    }

    /// Hands-mode parameters: `hands` full hands, `handsPerSolve` per flop solve, no triviality filter.
    /// `tree` nil = per-solve tree from the scenario's SPR (recommended; required for mixed stack depths).
    public static func hands(_ hands: Int = 120, handsPerSolve: Int = 3, format: GameFormat = .cash, scenarioIds: [String] = [],
                             seed: UInt64 = 1, tree: HandsTreeConfig? = nil, targetExploitability: Double = 0.75,
                             maxIterations: Int = 150, minEVSpread: Double = 0) -> SuiteParameters {
        var p = SuiteParameters(decisions: 0, streets: [.flop], scenarioIds: scenarioIds, seed: seed, minEVSpread: minEVSpread,
                                targetExploitability: tree?.targetExploitability ?? targetExploitability,
                                maxIterations: tree?.maxIterations ?? maxIterations, decisionsPerSolve: 0, concurrency: 1)
        p.mode = .hands
        p.hands = hands
        p.handsPerSolve = handsPerSolve
        p.handsTree = tree
        p.format = format.rawValue
        return p
    }

    public var suiteMode: SuiteMode { mode ?? .spots }
    public var gameFormat: GameFormat { format.flatMap(GameFormat.init(rawValue:)) ?? .cash }

    public var scenarios: [Scenario] {
        let s = scenarioIds.compactMap(Scenarios.named)
        if !s.isEmpty { return s }
        return format == nil ? Scenarios.all : Scenarios.forFormat(gameFormat)
    }
}

public enum SuiteMode: String, Codable, Sendable, CaseIterable {
    /// Independent decisions sampled from turn/river subgames that start from preflop ranges.
    case spots
    /// Complete hands played from the flop following GTO; every decision of both players is recorded.
    case hands
    /// Heads-up preflop (blind vs blind / spin HU) hands played with the preflop solver; every preflop decision.
    case preflop

    /// Suites whose decisions are grouped into hands (per-hand bb/100).
    public var hasHands: Bool { self != .spots }
}

/// Flop tree used by hands-mode suites. Lean on purpose so one solve takes ≈ 20–40 s on a 12-core M4 Pro.
public struct HandsTreeConfig: Codable, Hashable, Sendable {
    public var flopBetOOP: String
    public var flopBetIP: String
    public var flopRaise: String
    public var turnBet: String
    public var turnRaise: String
    public var riverBet: String
    public var riverRaise: String
    /// Raises allowed per street (after the first bet).
    public var raiseLimit: Int
    /// Offer an explicit all-in at every decision (shallow stacks). nil = false.
    public var addAllin: Bool? = nil
    /// Bets committing at least this fraction of the remaining stack become all-in.
    public var allinThreshold: Double
    /// Stop at this exploitability (% of the flop pot) …
    public var targetExploitability: Double
    /// … or after this many iterations.
    public var maxIterations: Int

    public init(flopBetOOP: String = "33", flopBetIP: String = "33", flopRaise: String = "60", turnBet: String = "66",
                turnRaise: String = "60", riverBet: String = "75", riverRaise: String = "60", raiseLimit: Int = 1,
                allinThreshold: Double = 0.67, targetExploitability: Double = 0.75, maxIterations: Int = 150) {
        self.flopBetOOP = flopBetOOP
        self.flopBetIP = flopBetIP
        self.flopRaise = flopRaise
        self.turnBet = turnBet
        self.turnRaise = turnRaise
        self.riverBet = riverBet
        self.riverRaise = riverRaise
        self.raiseLimit = raiseLimit
        self.allinThreshold = allinThreshold
        self.targetExploitability = targetExploitability
        self.maxIterations = maxIterations
    }

    /// Benchmarked default for deep stacks (see `SuiteGenerator.generateHands`).
    public static let standard = HandsTreeConfig()

    /// Tree by stack-to-pot ratio at the flop. Shallow trees are tiny (few bets fit before all-in), so
    /// they get an explicit all-in and, at very low SPR, a second flop size. The all-in threshold stays.
    /// * SPR ≥ 8 (cash single-raised): flop 33 · turn 66 · river 75 · raise 60 · 1 raise, no explicit all-in
    /// * 3 ≤ SPR < 8 (cash 3-bet, 40bb SRP, spin 25bb): same sizes + all-in
    /// * SPR < 3 (20bb, 15bb HU, 40bb 3-bet): flop 33/75 · turn 66 · river 75 + all-in · 1 raise
    public static func forSPR(_ spr: Double, targetExploitability: Double = 0.75, maxIterations: Int = 150) -> HandsTreeConfig {
        var t = HandsTreeConfig(targetExploitability: targetExploitability, maxIterations: maxIterations)
        if spr < 8 { t.addAllin = true }
        if spr < 3 { t.flopBetOOP = "33, 75"; t.flopBetIP = "33, 75" }
        return t
    }

    public var betSizes: BetSizes {
        BetSizes(flop: .init(oop: .init(bet: flopBetOOP, raise: flopRaise), ip: .init(bet: flopBetIP, raise: flopRaise)),
                 turn: .same(.init(bet: turnBet, raise: turnRaise)),
                 river: .same(.init(bet: riverBet, raise: riverRaise)))
    }

    /// "flop 33 (IP 33) / raise 60 · turn 66 / 60 · river 75 / 60 · 1 raise · all-in ≥ 67% stack".
    public var summary: String {
        let flop = flopBetOOP == flopBetIP ? "flop bet \(flopBetOOP)%" : "flop bet OOP \(flopBetOOP)% / IP \(flopBetIP)%"
        return "\(flop), raise \(flopRaise)% · turn bet \(turnBet)%, raise \(turnRaise)% · river bet \(riverBet)%, raise \(riverRaise)% · "
            + "\(raiseLimit) raise\(raiseLimit == 1 ? "" : "s") per street · " + (addAllin == true ? "explicit all-in · " : "")
            + "all-in when a bet commits ≥ \(Int((allinThreshold * 100).rounded()))% of the stack"
    }
}

/// One flop solve of a hands-mode suite (for metadata, timing and quality reporting).
public struct SolveRecord: Codable, Hashable, Sendable {
    public var index: Int
    public var scenarioId: String
    public var board: String
    public var iterations: Int
    /// Exploitability reached, % of the flop pot.
    public var exploitability: Double
    public var solveSeconds: Double
    public var sampleSeconds: Double
    public var memoryBytes: UInt64
    public var hands: Int
    public var decisions: Int
    /// Stack-to-pot ratio at the flop and the tree used (`HandsTreeConfig.summary`).
    public var spr: Double? = nil
    public var tree: String? = nil

    public init(index: Int, scenarioId: String, board: String, iterations: Int, exploitability: Double, solveSeconds: Double,
                sampleSeconds: Double, memoryBytes: UInt64, hands: Int, decisions: Int) {
        self.index = index
        self.scenarioId = scenarioId
        self.board = board
        self.iterations = iterations
        self.exploitability = exploitability
        self.solveSeconds = solveSeconds
        self.sampleSeconds = sampleSeconds
        self.memoryBytes = memoryBytes
        self.hands = hands
        self.decisions = decisions
    }
}

public struct BenchmarkSuite: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var parameters: SuiteParameters
    public var decisions: [Decision]
    public var solves: Int
    public var generationSeconds: Double
    /// Hands mode: per-solve metadata (exploitability reached, timings).
    public var solveRecords: [SolveRecord]? = nil

    public var mode: SuiteMode { parameters.suiteMode }
    /// Game format (hands suites record it; older suites are cash).
    public var format: GameFormat { parameters.gameFormat }
    /// Decisions are grouped by hand (hands and preflop suites): per-hand bb/100 applies.
    public var isHands: Bool { mode.hasHands }
    /// Distinct hands (hands suites), in order.
    public var handIds: [String] {
        var seen = Set<String>()
        return decisions.compactMap(\.handId).filter { seen.insert($0).inserted }
    }

    public init(id: String, name: String, createdAt: Date = Date(), parameters: SuiteParameters, decisions: [Decision],
                solves: Int, generationSeconds: Double) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.parameters = parameters
        self.decisions = decisions
        self.solves = solves
        self.generationSeconds = generationSeconds
    }

    public func decision(_ id: String) -> Decision? { decisions.first { $0.id == id } }

    public var countByStreet: [Street: Int] { Dictionary(grouping: decisions, by: \.street).mapValues(\.count) }
    public var countByScenario: [String: Int] { Dictionary(grouping: decisions, by: \.scenarioId).mapValues(\.count) }
}

// MARK: - Runs

public enum PlayerKind: String, Codable, Sendable, CaseIterable {
    /// OpenRouter System One decision model (typed `choice` question with probabilities).
    case decisionModel
    /// Offline reference bot that calibrates the scale.
    case baseline
    /// Post-hoc player computed from other runs' answers (ensemble, sharpened, guardrailed); no API calls.
    case derived

    public var title: String {
        switch self {
        case .decisionModel: return "Decision model"
        case .baseline: return "Baseline"
        case .derived: return "Derived"
        }
    }

    public var groupTitle: String {
        switch self {
        case .decisionModel: return "Decision models"
        case .baseline: return "Baselines"
        case .derived: return "Derived (post-hoc)"
        }
    }

    /// Display / grouping order: decision models, derived players, then bots.
    public var order: Int {
        switch self {
        case .decisionModel: return 0
        case .derived: return 1
        case .baseline: return 2
        }
    }

    /// Players whose answers carry action probabilities (scored as mixed strategies; invalid = worst).
    public var isProbabilistic: Bool { self != .baseline }
}

/// One sub-answer of a multi-question variant (`multi`, `noul`).
public struct AnswerPart: Codable, Hashable, Sendable {
    /// Question id.
    public var id: String
    /// Action the part picked (choice questions) or refers to (noul questions).
    public var choice: Int?
    /// Probability vector over the legal actions (choice questions).
    public var probabilities: [Double]?
    /// P(true) for noul questions.
    public var pTrue: Double?

    public init(id: String, choice: Int? = nil, probabilities: [Double]? = nil, pTrue: Double? = nil) {
        self.id = id
        self.choice = choice
        self.probabilities = probabilities
        self.pTrue = pTrue
    }
}

/// How a derived run was produced.
public struct DerivedInfo: Codable, Hashable, Sendable {
    /// `ensemble`, `temper`, `guardrail`.
    public var method: String
    /// Source run ids.
    public var sources: [String]
    public var parameters: [String: Double]
    public var description: String
    /// True when non-model information (heuristics) changed answers: not a pure model result.
    public var hybrid: Bool

    public init(method: String, sources: [String], parameters: [String: Double] = [:], description: String, hybrid: Bool = false) {
        self.method = method
        self.sources = sources
        self.parameters = parameters
        self.description = description
        self.hybrid = hybrid
    }
}

/// One player's answer to one decision.
public struct DecisionResult: Codable, Hashable, Sendable, Identifiable {
    public var decisionId: String
    /// Chosen action index; nil = invalid / failed answer (scored as the worst action).
    public var choice: Int?
    public var rawResponse: String?
    public var error: String?
    public var latency: Double
    public var promptTokens: Int
    public var completionTokens: Int
    public var cost: Double
    public var answeredAt: Date
    /// Probability the player assigns to each legal action (same order as `Decision.actions`, sums to 1).
    /// Set by decision models and the sampled-GTO baseline; nil for argmax-only baselines and failed answers.
    public var actionProbabilities: [Double]?
    /// Decision model's reported confidence in its choice (0–1).
    public var confidence: Double?
    /// Multi-question variants: each question's answer (the result combines them).
    public var parts: [AnswerPart]? = nil

    public var id: String { decisionId }
    public var isValid: Bool { choice != nil }

    public init(decisionId: String, choice: Int?, rawResponse: String? = nil, error: String? = nil,
                latency: Double = 0, promptTokens: Int = 0, completionTokens: Int = 0,
                cost: Double = 0, answeredAt: Date = Date(), actionProbabilities: [Double]? = nil, confidence: Double? = nil) {
        self.decisionId = decisionId
        self.choice = choice
        self.rawResponse = rawResponse
        self.error = error
        self.latency = latency
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cost = cost
        self.answeredAt = answeredAt
        self.actionProbabilities = actionProbabilities
        self.confidence = confidence
    }
}

/// All answers of one player on one suite.
public struct BenchmarkRun: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var suiteId: String
    /// OpenRouter model id or "baseline:<name>".
    public var model: String
    public var displayName: String
    public var kind: PlayerKind
    /// `DecisionStateBuilder.version` for decision-model runs (nil for baselines).
    public var stateVersion: Int?
    /// State/question variant (`DecisionVariants`) for decision-model runs; nil in old runs (= `v2`).
    public var variant: String? = nil
    /// Set for derived (post-hoc) runs.
    public var derived: DerivedInfo? = nil
    public var createdAt: Date
    public var updatedAt: Date
    public var results: [DecisionResult]

    public init(suiteId: String, model: String, displayName: String, kind: PlayerKind, variant: String? = nil) {
        self.id = BenchmarkRun.makeId(suiteId: suiteId, model: model, variant: variant)
        self.suiteId = suiteId
        self.model = model
        self.displayName = displayName
        self.kind = kind
        self.variant = kind == .decisionModel ? (variant ?? DecisionVariants.defaultId) : variant
        self.stateVersion = kind == .decisionModel ? DecisionStateBuilder.version : nil
        self.createdAt = Date()
        self.updatedAt = Date()
        self.results = []
    }

    /// Stable id so re-running the same model (and variant) on a suite resumes. The default variant
    /// keeps the legacy id (`<suite>__<model>`) so runs made before variants existed still resume.
    public static func makeId(suiteId: String, model: String, variant: String? = nil) -> String {
        let suffix = variant.map { $0 == DecisionVariants.defaultId ? "" : "__\($0)" } ?? ""
        return "\(suiteId)__\(model)\(suffix)".map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" }
            .reduce(into: "") { $0.append($1) }
    }

    /// Variant id for display (decision models default to `v2`).
    public var variantId: String? { variant ?? (kind == .decisionModel ? DecisionVariants.defaultId : nil) }

    /// Display label: "typesafe/jev-1.13 [eq]" for decision models, the name for baselines/derived runs.
    public var label: String {
        guard kind == .decisionModel, let v = variantId else { return displayName }
        return "\(displayName) [\(v)]"
    }

    public func result(for decisionId: String) -> DecisionResult? { results.first { $0.decisionId == decisionId } }
    public var answeredIds: Set<String> { Set(results.map(\.decisionId)) }
    public var totalCost: Double { results.reduce(0) { $0 + $1.cost } }
}

// MARK: - Formatting helpers

public enum BB {
    /// "4.1", "12", "0.55" — compact big-blind amounts.
    public static func fmt(_ x: Double) -> String {
        if abs(x - x.rounded()) < 0.05 { return String(Int(x.rounded())) }
        if abs(x) < 1 { return String(format: "%.2f", x) }
        return String(format: "%.1f", x)
    }

    public static func pct(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }
}
