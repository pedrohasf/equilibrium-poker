import ArenaKit
import Foundation
import OpenRouterKit
import Observation
import SolverKit

/// What the felt table renders: one hand from the point of view of a spectator.
struct TableSnapshot: Equatable {
    var hand: Int?
    var deal: Int = 0
    var replica: Int = 0
    var state: HandState?
    /// Player (0 = A, 1 = B) in each seat.
    var seatPlayers: [Int] = [0, 1]
    /// Latest action by player.
    var lastAction: [Int: ActionRecord] = [:]
    /// Player currently deciding.
    var thinking: Int?

    func seat(of player: Int) -> Int { seatPlayers.firstIndex(of: player) ?? player }
    var result: HandResult? { state?.result }
}

struct LogEntry: Identifiable, Equatable {
    enum Kind { case hand, action, street, showdown, result, info, error }
    let id: Int
    let hand: Int?
    let kind: Kind
    let text: String
    var detail: String?
    var player: Int?
}

struct CumulativePoint: Identifiable, Equatable {
    var id: Int { index }
    let index: Int
    let hand: Int
    let net: Double
    let ev: Double
}

enum PlaySpeed: String, CaseIterable, Identifiable {
    case animate, fast
    var id: String { rawValue }
    var title: String { self == .animate ? "Animate" : "Fast-forward" }
    var icon: String { self == .animate ? "play.fill" : "forward.fill" }
    var delay: Double { self == .animate ? 0.9 : 0 }
}

/// A match being played in the app.
@MainActor @Observable
final class LiveMatch {
    let id: String
    let specs: [PlayerSpec]
    let config: MatchConfig
    let pace: PaceController
    var status: MatchStatus = .running
    var table = TableSnapshot()
    var log: [LogEntry] = []
    var points: [CumulativePoint] = []
    var progress: MatchProgress?
    var record: MatchRecord?
    /// Last bot rationale per player (0 = A, 1 = B).
    var rationale: [Int: (hand: Int, text: String)] = [:]
    /// Last decision-model probability vector per player.
    var decisions: [Int: (hand: Int, trace: DecisionTrace, fallback: Bool)] = [:]
    var speed: PlaySpeed {
        didSet { pace.delay = speed.delay }
    }
    var paused = false {
        didSet { pace.paused = paused }
    }
    var startedAt = Date()

    private var task: Task<MatchRecord, Never>?
    private var consumer: Task<Void, Never>?
    private var logCounter = 0
    private var inProgress: [Int: TableSnapshot] = [:]
    private var holdUntil: Date?

    init(config: MatchConfig, specs: [PlayerSpec], players: [any ArenaPlayer], speed: PlaySpeed, onFinish: @escaping @MainActor (MatchRecord) -> Void) {
        id = MatchRecord.newID()
        self.specs = specs
        self.config = config
        self.speed = speed
        pace = PaceController(delay: speed.delay)
        let (events, task) = MatchRunner.stream(id: id, config: config, specs: specs, players: players, pace: pace)
        self.task = task
        consumer = Task { [weak self] in
            for await e in events {
                guard let self else { return }
                self.handle(e)
            }
            if let self, let r = self.record { onFinish(r) }
        }
    }

    var isRunning: Bool { status == .running }
    var title: String { "\(specs[0].displayName) vs \(specs[1].displayName)" }

    func cancel() {
        paused = false
        task?.cancel()
    }

    func name(_ p: Int) -> String { specs[p].displayName }

    private func addLog(_ kind: LogEntry.Kind, hand: Int?, _ text: String, detail: String? = nil, player: Int? = nil) {
        logCounter += 1
        log.append(LogEntry(id: logCounter, hand: hand, kind: kind, text: text, detail: detail, player: player))
        if log.count > 800 { log.removeFirst(log.count - 800) }
    }

    /// The table follows one hand at a time; others still feed the log and totals.
    private func feature(_ hand: Int) -> Bool {
        if table.hand == hand { return true }
        if let until = holdUntil, Date() < until, table.state?.isComplete == true { return false }
        if table.hand == nil || table.state?.isComplete == true || inProgress[table.hand ?? -1] == nil {
            if let snap = inProgress[hand] {
                table = snap
                return true
            }
        }
        return false
    }

    private func handle(_ e: MatchEvent) {
        switch e {
        case .started:
            addLog(.info, hand: nil, "Match started · \(config.totalHands) hands")
        case let .handStarted(hand, deal, replica, seatPlayers, state):
            let snap = TableSnapshot(hand: hand, deal: deal, replica: replica, state: state, seatPlayers: seatPlayers)
            inProgress[hand] = snap
            let btn = specs[seatPlayers[0]].displayName
            addLog(.hand, hand: hand, "Hand #\(hand) · deal \(deal + 1)\(config.duplicate ? (replica == 0 ? "a" : "b") : "") · \(btn) on the button",
                   detail: "\(name(seatPlayers[0])) \(state.hole[0].text)   \(name(seatPlayers[1])) \(state.hole[1].text)")
            _ = feature(hand)
        case let .thinking(hand, player, state):
            inProgress[hand]?.state = state
            inProgress[hand]?.thinking = player
            if feature(hand) { table.thinking = player; table.state = state }
        case let .action(hand, player, record, state):
            inProgress[hand]?.state = state
            inProgress[hand]?.thinking = nil
            inProgress[hand]?.lastAction[player] = record
            if feature(hand) {
                if record.street != table.state?.street { table.lastAction = [:] }
                table.state = state
                table.thinking = nil
                table.lastAction[player] = record
            }
            if let t = record.meta?.decision {
                decisions[player] = (hand, t, record.meta?.fallback == true)
            } else if let r = record.meta?.reasoning, !r.isEmpty, feature(hand) {
                rationale[player] = (hand, r)
            }
            var detail: String? = specs[player].usesOpenRouter ? record.meta?.reasoning : nil
            if let m = record.meta, m.fallback { detail = "Invalid / failed decision → \(record.kind.rawValue). \(m.errorMessage ?? "")" }
            addLog(m(record), hand: hand, "\(name(player)) \(ActionText.verb(record))", detail: detail, player: player)
        case let .street(hand, street, state):
            inProgress[hand]?.state = state
            inProgress[hand]?.lastAction = [:]
            if feature(hand) {
                table.state = state
                table.lastAction = [:]
            }
            addLog(.street, hand: hand, "\(street.name) \(state.board.text)")
        case let .showdown(hand, state):
            inProgress[hand]?.state = state
            if feature(hand) { table.state = state }
            if let r = state.result {
                var text = "Showdown"
                if let c = r.categories { text += ": \(c[0].lowercased()) vs \(c[1].lowercased())" }
                if let eq = r.allInEquity { text += String(format: " · all-in equity %.0f%% / %.0f%%", eq[0] * 100, eq[1] * 100) }
                addLog(.showdown, hand: hand, text)
            }
        case let .handFinished(rec, p):
            inProgress[rec.number] = nil
            if table.hand == rec.number {
                table.state = HandState.finalState(of: rec)
                table.thinking = nil
                holdUntil = Date().addingTimeInterval(speed == .animate ? 1.6 : 0.25)
            }
            progress = p
            points.append(CumulativePoint(index: points.count + 1, hand: rec.number, net: p.net[0], ev: p.evNet[0]))
            let a = rec.net(0)
            let winner = a > 0 ? name(0) : (a < 0 ? name(1) : "Split")
            addLog(.result, hand: rec.number, a == 0 ? "Hand #\(rec.number): split pot" : "Hand #\(rec.number): \(winner) wins \(Chips.text(abs(rec.result.net[0])) ) bb",
                   player: a > 0 ? 0 : (a < 0 ? 1 : nil))
        case let .finished(r):
            record = r
            status = r.status
            if let err = r.error { addLog(.error, hand: nil, err) }
            addLog(.info, hand: nil, "Match \(r.status.rawValue) · \(r.hands.count) hands")
        }
    }

    private func m(_ r: ActionRecord) -> LogEntry.Kind { r.meta?.fallback == true ? .error : .action }
}

extension HandState {
    /// The finished state with the recorded result (including all-in EV).
    static func finalState(of rec: HandRecord) -> HandState {
        var s = rec.initialState
        for a in rec.actions { try? s.apply(a.action, meta: a.meta) }
        s.computeAllInEV { _, _, _ in rec.result.allInEquity?[0] }
        return s
    }
}

enum ActionText {
    static func verb(_ a: ActionRecord) -> String {
        let allIn = a.allIn ? " (all-in)" : ""
        switch a.kind {
        case .fold: return "folds"
        case .check: return "checks"
        case .call: return "calls \(Chips.text(a.amount))\(allIn)"
        case .bet: return "bets \(Chips.text(a.to))\(allIn)"
        case .raise: return "raises to \(Chips.text(a.to))\(allIn)"
        }
    }

    static func short(_ a: ActionRecord) -> String {
        switch a.kind {
        case .fold: return "Fold"
        case .check: return "Check"
        case .call: return a.allIn ? "Call all-in" : "Call \(Chips.text(a.amount))"
        case .bet: return a.allIn ? "All-in \(Chips.text(a.to))" : "Bet \(Chips.text(a.to))"
        case .raise: return a.allIn ? "All-in \(Chips.text(a.to))" : "Raise \(Chips.text(a.to))"
        }
    }
}

/// App-wide arena state (survives switching sections).
@MainActor @Observable
final class ArenaStore {
    static let shared = ArenaStore()

    var matches: [MatchRecord] = []
    var leaderboard: [LeaderboardEntry] = []
    var live: LiveMatch?
    /// System One decision models in the live OpenRouter catalog.
    var catalog: [ModelInfo] = []
    var catalogError: String?
    var loadingCatalog = false

    private init() { reload() }

    var hasAPIKey: Bool { !(APIKeyStore.current ?? "").isEmpty }

    func reload() {
        matches = MatchStore.all()
        leaderboard = Leaderboard.compute(matches)
    }

    func delete(_ id: String) {
        try? MatchStore.delete(id)
        reload()
    }

    func loadCatalog() async {
        guard catalog.isEmpty, !loadingCatalog, hasAPIKey else { return }
        loadingCatalog = true
        defer { loadingCatalog = false }
        do {
            catalog = try await OpenRouterClient.fromStoredKey().decisionModels().sorted { $0.id < $1.id }
            catalogError = nil
        } catch {
            catalogError = error.localizedDescription
        }
    }

    func price(for model: String) -> ModelInfo? { catalog.first { $0.id == model } }

    var decisionIDs: Set<String> { Set(catalog.map(\.id)) }

    /// Suggested decision models that exist in the live catalog (all suggestions while it is not loaded).
    var suggestedDecisionModels: [String] {
        let live = decisionIDs
        return live.isEmpty ? DecisionRoster.suggested : DecisionRoster.suggested.filter { live.contains($0) }
    }

    func start(config: MatchConfig, specs: [PlayerSpec], speed: PlaySpeed) throws {
        let needsKey = specs.contains { $0.usesOpenRouter }
        let client: OpenRouterClient? = needsKey ? try OpenRouterClient.fromStoredKey(maxConcurrent: max(4, config.concurrency * 2)) : nil
        let players = try specs.map { try PlayerFactory.make($0, decisions: client, includeMatchSummary: config.opponentStats) }
        live?.cancel()
        live = LiveMatch(config: config, specs: specs, players: players, speed: speed) { [weak self] _ in
            self?.reload()
        }
    }
}

/// Rough cost estimate for a match.
enum CostEstimate {
    /// Average decisions per player per hand (measured from bot matches).
    static let decisionsPerHand = 1.9
    /// Decision models: JSON state + criteria (input only; output is free).
    static let decisionPromptTokens = 1100.0

    /// USD estimate for one player's side, nil when pricing is unknown.
    static func usd(spec: PlayerSpec, hands: Int, info: ModelInfo?) -> Double? {
        let calls = Double(hands) * decisionsPerHand
        switch spec.kind {
        case .bot: return 0
        case .decision:
            guard let info, let pin = info.promptPrice else { return nil }
            return calls * decisionPromptTokens * pin
        }
    }
}
