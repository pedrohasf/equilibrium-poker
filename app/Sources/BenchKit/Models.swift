import Foundation
import LLMKit
import SolverKit

// MARK: - Streets

public enum Street: String, Codable, CaseIterable, Sendable, Comparable, Identifiable {
    case flop, turn, river

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    /// Number of board cards on this street.
    public var boardCount: Int { 3 + order }
    public var order: Int { Street.allCases.firstIndex(of: self)! }

    public init?(boardCount: Int) {
        switch boardCount {
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

    public init(kind: ActionKind, amount: Double, to: Double, potFraction: Double) {
        self.kind = kind
        self.amount = amount
        self.to = to
        self.potFraction = potFraction
    }

    public init(_ a: ActionInfo) {
        self.init(kind: a.kind, amount: Double(a.amount), to: Double(a.to), potFraction: Double(a.potFraction))
    }

    /// Exact label used in prompts and parsing, e.g. "Bet 4.1 bb", "Raise to 12.5 bb".
    public var label: String {
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
        guard kind.isAggressive, potFraction > 0 else { return label }
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

    public var heroPosition: String { positions[heroSeat] }
    public var villainPosition: String { positions[1 - heroSeat] }
    public var heroIsIP: Bool { heroSeat == 1 }
    public var bestEV: Double { actionEVs.max() ?? 0 }
    public var worstEV: Double { actionEVs.min() ?? 0 }
    /// Range of action EVs (bb).
    public var evSpread: Double { bestEV - worstEV }
    public var bestAction: Int { actionEVs.indices.max { actionEVs[$0] < actionEVs[$1] } ?? 0 }
    public var gtoAction: Int { strategy.indices.max { strategy[$0] < strategy[$1] } ?? 0 }
    public var facingBet: Bool { toCall > 0 }
    public var decisionType: DecisionType { facingBet ? .facingBet : .firstToAct }

    public var heroCardList: [Card] { Card.parseList(heroCards) ?? [] }
    public var boardCards: [Card] { board.compactMap(Card.init) }

    /// EV lost by choosing `index` (bb); invalid choices cost the full spread.
    public func evLoss(_ index: Int?) -> Double {
        guard let i = index, actionEVs.indices.contains(i) else { return evSpread }
        return max(0, bestEV - actionEVs[i])
    }

    /// Compact one-line description for lists and logs.
    public var headline: String {
        "\(street.title) · \(heroPosition) \(facingBet ? "facing \(BB.fmt(toCall)) bb" : "to act") · \(heroCards) on \(board.joined(separator: " "))"
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

    public var scenarios: [Scenario] {
        let s = scenarioIds.compactMap(Scenarios.named)
        return s.isEmpty ? Scenarios.all : s
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

public enum PlayerKind: String, Codable, Sendable {
    case llm, baseline
}

/// One player's answer to one decision.
public struct DecisionResult: Codable, Hashable, Sendable, Identifiable {
    public var decisionId: String
    /// Chosen action index; nil = invalid / failed answer (scored as the worst action).
    public var choice: Int?
    public var rawResponse: String?
    public var reasoning: String?
    public var error: String?
    public var latency: Double
    public var promptTokens: Int
    public var completionTokens: Int
    public var reasoningTokens: Int
    public var cost: Double
    public var answeredAt: Date

    public var id: String { decisionId }
    public var isValid: Bool { choice != nil }

    public init(decisionId: String, choice: Int?, rawResponse: String? = nil, reasoning: String? = nil, error: String? = nil,
                latency: Double = 0, promptTokens: Int = 0, completionTokens: Int = 0, reasoningTokens: Int = 0,
                cost: Double = 0, answeredAt: Date = Date()) {
        self.decisionId = decisionId
        self.choice = choice
        self.rawResponse = rawResponse
        self.reasoning = reasoning
        self.error = error
        self.latency = latency
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.reasoningTokens = reasoningTokens
        self.cost = cost
        self.answeredAt = answeredAt
    }
}

/// All answers of one player (model + options) on one suite.
public struct BenchmarkRun: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var suiteId: String
    /// OpenRouter model id or "baseline:<name>".
    public var model: String
    public var displayName: String
    public var kind: PlayerKind
    public var options: ChatOptions?
    public var promptVersion: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var results: [DecisionResult]

    public init(suiteId: String, model: String, displayName: String, kind: PlayerKind, options: ChatOptions?,
                promptVersion: Int = PromptBuilder.version) {
        self.id = BenchmarkRun.makeId(suiteId: suiteId, model: model, options: options)
        self.suiteId = suiteId
        self.model = model
        self.displayName = displayName
        self.kind = kind
        self.options = options
        self.promptVersion = promptVersion
        self.createdAt = Date()
        self.updatedAt = Date()
        self.results = []
    }

    /// Stable id so re-running the same model/options on a suite resumes.
    public static func makeId(suiteId: String, model: String, options: ChatOptions?) -> String {
        var s = "\(suiteId)__\(model)"
        if let e = options?.reasoningEffort { s += "__r-\(e)" }
        if let t = options?.temperature { s += "__t\(t)" }
        return s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" }.reduce(into: "") { $0.append($1) }
    }

    /// Label including options, e.g. "openai/gpt-5 · low".
    public var label: String {
        var s = displayName
        if let e = options?.reasoningEffort { s += " · \(e)" }
        return s
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
