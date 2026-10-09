import Foundation
import SolverKit

/// Running totals delivered with each finished hand.
public struct MatchProgress: Sendable, Hashable {
    public var handsDone: Int
    public var handsTotal: Int
    /// Net big blinds for A and B (B = -A).
    public var net: [Double]
    public var evNet: [Double]
    public var cost: [Double]
    public var invalid: [Int]
}

/// Live events for UIs and the CLI. `state` snapshots are taken right after the event.
public enum MatchEvent: Sendable {
    case started(MatchRecord)
    case handStarted(hand: Int, deal: Int, replica: Int, seatPlayers: [Int], state: HandState)
    /// `player` (0 = A, 1 = B) is about to decide.
    case thinking(hand: Int, player: Int, state: HandState)
    case action(hand: Int, player: Int, record: ActionRecord, state: HandState)
    case street(hand: Int, street: Street, state: HandState)
    case showdown(hand: Int, state: HandState)
    case handFinished(HandRecord, MatchProgress)
    case finished(MatchRecord)

    public var handNumber: Int? {
        switch self {
        case .handStarted(let h, _, _, _, _), .thinking(let h, _, _), .action(let h, _, _, _), .street(let h, _, _), .showdown(let h, _):
            return h
        case .handFinished(let r, _): return r.number
        case .started, .finished: return nil
        }
    }
}

/// Live speed control: a delay after every action and a pause switch.
public final class PaceController: @unchecked Sendable {
    private let lock = NSLock()
    private var _delay: Double
    private var _paused = false

    public init(delay: Double = 0) { _delay = delay }

    public var delay: Double {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = max(0, newValue) } }
    }

    public var paused: Bool {
        get { lock.withLock { _paused } }
        set { lock.withLock { _paused = newValue } }
    }

    func wait() async throws {
        let d = delay
        if d > 0 { try await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000)) }
        while paused {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

/// Shared mutable state of a running match.
actor MatchLedger {
    let specs: [PlayerSpec]
    let total: Int
    private(set) var hands: [HandRecord] = []
    private var net = [0.0, 0.0], ev = [0.0, 0.0], cost = [0.0, 0.0]
    private var invalid = [0, 0]
    private var errorStreak = [0, 0]

    init(specs: [PlayerSpec], total: Int) {
        self.specs = specs
        self.total = total
    }

    func add(_ h: HandRecord) -> MatchProgress {
        hands.append(h)
        for p in 0..<2 {
            net[p] += h.net(p)
            ev[p] += h.evNet(p)
            for a in h.actions where a.seat == h.seat(of: p) {
                cost[p] += a.meta?.cost ?? 0
                if a.meta?.fallback == true { invalid[p] += 1 }
            }
        }
        return MatchProgress(handsDone: hands.count, handsTotal: total, net: net, evNet: ev, cost: cost, invalid: invalid)
    }

    func summary(for player: Int) -> String? {
        MatchStats.promptSummary(hands.sorted { $0.number < $1.number }, me: player, specs: specs)
    }

    /// Tracks consecutive hard failures (no response at all); returns the streak.
    func noteDecision(player: Int, hardFailure: Bool) -> Int {
        errorStreak[player] = hardFailure ? errorStreak[player] + 1 : 0
        return errorStreak[player]
    }
}

public enum MatchRunner {
    /// Consecutive failed requests after which a match is aborted (e.g. bad key, no credits).
    public static let maxConsecutiveFailures = 6

    public typealias EquityFunction = @Sendable (_ hero: [Card], _ villain: [Card], _ board: [Card]) -> Double?

    /// Plays a full match. Never throws: cancellation and failures are reflected in `status`.
    public static func run(id: String = MatchRecord.newID(), config: MatchConfig, specs: [PlayerSpec], players: [any ArenaPlayer],
                           pace: PaceController? = nil, save: Bool = true,
                           equity: @escaping EquityFunction = { HandState.coreEquity($0, $1, $2) },
                           onEvent: @escaping @Sendable (MatchEvent) -> Void = { _ in }) async -> MatchRecord {
        precondition(specs.count == 2 && players.count == 2)
        var record = MatchRecord(id: id, config: config, players: specs)
        onEvent(.started(record))
        let ledger = MatchLedger(specs: specs, total: config.totalHands)

        @Sendable func playHand(deal: Int, replica: Int) async throws -> HandRecord {
            let start = Date()
            let number = config.duplicate ? deal * 2 + replica + 1 : deal + 1
            let seatPlayers = replica == 0 ? [0, 1] : [1, 0]
            var state = HandState(cards: Deck.deal(seed: config.seed, index: deal), config: config.handConfig)
            onEvent(.handStarted(hand: number, deal: deal, replica: replica, seatPlayers: seatPlayers, state: state))
            while let seat = state.toAct {
                try Task.checkCancellation()
                let p = seatPlayers[seat]
                let summary = config.opponentStats ? await ledger.summary(for: p) : nil
                let ctx = DecisionContext(state: state, seat: seat, menu: ActionMenu.build(for: state), handNumber: number,
                                          rngSeed: SeededRNG.mix(config.seed, UInt64(deal), UInt64(state.actions.count), UInt64(seat)),
                                          matchSummary: summary)
                onEvent(.thinking(hand: number, player: p, state: state))
                var decision: Decision
                do {
                    decision = try await players[p].decide(ctx)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    decision = Decision(ActionMenu.passive(for: state),
                                        meta: DecisionMeta(errors: 1, fallback: true, errorMessage: error.localizedDescription))
                }
                if !state.isLegal(decision.action) {
                    var m = decision.meta ?? DecisionMeta()
                    m.fallback = true
                    m.errors += 1
                    m.errorMessage = m.errorMessage ?? "illegal action \(decision.action)"
                    decision = Decision(ActionMenu.passive(for: state), meta: m)
                }
                let hard = decision.meta.map { $0.fallback && $0.raw.isEmpty && $0.errorMessage != nil } ?? false
                if await ledger.noteDecision(player: p, hardFailure: hard) >= maxConsecutiveFailures {
                    throw EngineError("\(specs[p].id) failed \(maxConsecutiveFailures) times in a row: \(decision.meta?.errorMessage ?? "unknown error")")
                }
                let board = state.boardCount
                try state.apply(decision.action, meta: decision.meta)
                onEvent(.action(hand: number, player: p, record: state.actions.last!, state: state))
                if state.boardCount != board, let dealt = Street.allCases.last(where: { $0.boardCount <= state.boardCount }) {
                    onEvent(.street(hand: number, street: dealt, state: state))
                }
                if let pace { try await pace.wait() }
            }
            state.computeAllInEV(equity: equity)
            if state.result?.showdown == true { onEvent(.showdown(hand: number, state: state)) }
            let rec = HandRecord(number: number, deal: deal, replica: replica, seatPlayers: seatPlayers, state: state,
                                 duration: Date().timeIntervalSince(start))
            let progress = await ledger.add(rec)
            onEvent(.handFinished(rec, progress))
            if let pace { try await pace.wait() }
            return rec
        }

        @Sendable func playDeal(_ d: Int) async throws {
            let replicas = config.duplicate ? [0, 1] : [d % 2]
            for r in replicas { _ = try await playHand(deal: d, replica: r) }
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = 0
                let width = max(1, min(config.concurrency, config.deals))
                while next < width {
                    let d = next
                    group.addTask { try await playDeal(d) }
                    next += 1
                }
                while try await group.next() != nil {
                    if next < config.deals {
                        let d = next
                        group.addTask { try await playDeal(d) }
                        next += 1
                    }
                }
            }
            record.status = .completed
        } catch is CancellationError {
            record.status = .cancelled
        } catch {
            record.status = Task.isCancelled ? .cancelled : .failed
            if record.status == .failed { record.error = error.localizedDescription }
        }
        record.hands = await ledger.hands.sorted { $0.number < $1.number }
        record.finishedAt = Date()
        record.recomputeSummary()
        if save && !record.hands.isEmpty { try? MatchStore.save(record) }
        onEvent(.finished(record))
        return record
    }

    /// Starts a match in a task and exposes its events as an AsyncStream. Cancel the task to stop.
    public static func stream(id: String = MatchRecord.newID(), config: MatchConfig, specs: [PlayerSpec], players: [any ArenaPlayer],
                              pace: PaceController? = nil, save: Bool = true) -> (events: AsyncStream<MatchEvent>, task: Task<MatchRecord, Never>) {
        let (stream, cont) = AsyncStream<MatchEvent>.makeStream(bufferingPolicy: .unbounded)
        let task = Task {
            let r = await run(id: id, config: config, specs: specs, players: players, pace: pace, save: save, onEvent: { cont.yield($0) })
            cont.finish()
            return r
        }
        return (stream, task)
    }
}
