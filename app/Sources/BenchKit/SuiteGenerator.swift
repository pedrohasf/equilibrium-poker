import Foundation
import OpenRouterKit
import SolverKit

// MARK: - Deterministic RNG

/// SplitMix64: tiny, fast and reproducible across platforms.
public struct SeededRNG: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    /// Derives an independent stream for sub-task `index`.
    public init(seed: UInt64, stream: UInt64) {
        var s = SeededRNG(seed: seed ^ (stream &* 0x9E37_79B9_7F4A_7C15))
        _ = s.next()
        state = s.next()
    }

    /// Stable seed from strings (FNV-1a), e.g. for per-decision baseline sampling.
    public static func hash(_ parts: String...) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for p in parts {
            for b in p.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
            h = (h ^ 0xff) &* 0x100_0000_01b3
        }
        return h
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// Index sampled proportionally to `weights` (nil if all zero).
    public mutating func weightedIndex<C: Collection>(_ weights: C) -> Int? where C.Element == Double {
        let total = weights.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else { return nil }
        var x = unit() * total
        var last: Int?
        for (i, w) in weights.enumerated() where w > 0 {
            last = i
            x -= w
            if x < 0 { return i }
        }
        return last
    }
}

// MARK: - Generation

public struct GenerationProgress: Sendable {
    public var solvesDone: Int
    public var decisions: Int
    public var target: Int
    public var elapsed: Double
    public var lastSpot: String?

    public init(solvesDone: Int, decisions: Int, target: Int, elapsed: Double, lastSpot: String?) {
        self.solvesDone = solvesDone
        self.decisions = decisions
        self.target = target
        self.elapsed = elapsed
        self.lastSpot = lastSpot
    }
}

/// Builds benchmark suites: solve random subgames, then sample realistic decisions from them.
///
/// Approximation: the solved subgame starts on the turn or river with the *preflop* ranges of the
/// scenario. Earlier streets are summarised by a synthetic line (check-through or a small bet and
/// call) that sets the pot and stacks, but ranges are not narrowed by that line. Decisions are still
/// exact equilibrium answers *for the stated subgame*, which is what players are scored against.
/// Decisions are sampled on the subgame's root street only (a turn solve yields turn decisions).
public enum SuiteGenerator {
    /// Street pattern of a synthetic (unsolved) earlier street.
    enum PriorPattern {
        case checkThrough
        case ipBetCall(Double)
        case oopBetCall(Double)
    }

    struct Subgame {
        var config: SolverConfig
        var history: [HistoryEntry]
    }

    /// Lean but sensible trees. Two sizes on turn and river; flop stays minimal because it is slow.
    public static func betSizes(root: Street) -> (BetSizes, Int) {
        switch root {
        case .river:
            return (BetSizes(river: .same(.init(bet: "33, 75", raise: "60"))), 2)
        case .turn:
            return (BetSizes(turn: .same(.init(bet: "33, 75", raise: "60")), river: .same(.init(bet: "33, 75", raise: "60"))), 1)
        case .flop, .preflop:
            return (BetSizes.standard, 1)
        }
    }

    static func samplePattern(_ street: Street, rng: inout SeededRNG) -> PriorPattern {
        let u = rng.unit()
        if street == .flop {
            return u < 0.35 ? .checkThrough : (u < 0.8 ? .ipBetCall(0.33) : .oopBetCall(0.33))
        }
        return u < 0.45 ? .checkThrough : (u < 0.8 ? .ipBetCall(0.75) : .oopBetCall(0.75))
    }

    /// Builds the subgame config plus the synthetic history leading to it.
    static func subgame(scenario: Scenario, root: Street, board: [Card], rng: inout SeededRNG) -> Subgame {
        var pot = scenario.pot
        var stack = scenario.stack
        var history: [HistoryEntry] = []
        for street in Street.postflop where street < root {
            if street > .flop {
                history.append(HistoryEntry(street: street, seat: nil, action: nil, potBefore: pot,
                                            card: board[street.boardCount - 1].description, synthetic: true))
            }
            func act(_ seat: Int, _ kind: ActionKind, _ amount: Double, _ frac: Double) {
                history.append(HistoryEntry(street: street, seat: seat,
                                            action: SpotAction(kind: kind, amount: amount, to: amount, potFraction: frac),
                                            potBefore: pot, synthetic: true))
                pot += amount
            }
            switch samplePattern(street, rng: &rng) {
            case .checkThrough:
                act(0, .check, 0, 0)
                act(1, .check, 0, 0)
            case .ipBetCall(let f):
                let b = (f * pot * 100).rounded() / 100
                act(0, .check, 0, 0)
                act(1, .bet, b, f)
                act(0, .call, b, 0)
                stack -= b
            case .oopBetCall(let f):
                let b = (f * pot * 100).rounded() / 100
                act(0, .bet, b, f)
                act(1, .call, b, 0)
                stack -= b
            }
        }
        if root > .flop {
            history.append(HistoryEntry(street: root, seat: nil, action: nil, potBefore: pot,
                                        card: board[root.boardCount - 1].description, synthetic: true))
        }
        let (sizes, raiseLimit) = betSizes(root: root)
        let cfg = SolverConfig(board: board.text, rangeOOP: scenario.rangeOOP, rangeIP: scenario.rangeIP,
                               startingPot: (pot * 100).rounded() / 100, effectiveStack: (stack * 100).rounded() / 100,
                               betSizes: sizes, allinThreshold: 0.67, addAllin: false, raiseLimit: raiseLimit)
        return Subgame(config: cfg, history: history)
    }

    /// Generates a full suite with bounded parallelism. Deterministic for a given seed
    /// (up to floating-point differences in the multithreaded solver).
    public static func generate(_ params: SuiteParameters, name: String? = nil,
                                progress: @escaping @Sendable (GenerationProgress) -> Void = { _ in }) async throws -> BenchmarkSuite {
        let start = Date()
        let target = max(1, params.decisions)
        var results: [Int: [Decision]] = [:]
        var collected = 0
        var nextIndex = 0
        let maxSpots = target * 6 + 20
        let width = max(1, params.concurrency)

        try await withThrowingTaskGroup(of: (Int, [Decision]).self) { group in
            func launch() {
                let i = nextIndex
                nextIndex += 1
                group.addTask { (i, try await generateSpot(index: i, params: params)) }
            }
            for _ in 0..<width { launch() }
            while let (i, ds) = try await group.next() {
                results[i] = ds
                collected += ds.count
                progress(GenerationProgress(solvesDone: results.count, decisions: min(collected, target), target: target,
                                            elapsed: Date().timeIntervalSince(start), lastSpot: ds.first?.headline))
                if collected < target && nextIndex < maxSpots { launch() }
            }
        }

        var decisions: [Decision] = []
        for i in results.keys.sorted() { decisions += results[i]! }
        decisions = Array(decisions.prefix(target))
        for i in decisions.indices { decisions[i].id = String(format: "d%03d", i + 1) }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = df.string(from: start)
        let streets = params.streets.map { String($0.rawValue.prefix(1)) }.joined()
        let id = "\(stamp)-\(streets)-n\(decisions.count)-s\(params.seed)"
        return BenchmarkSuite(id: id, name: name ?? "\(decisions.count) decisions · \(params.streets.map(\.title).joined(separator: "+")) · seed \(params.seed)",
                              createdAt: start, parameters: params, decisions: decisions, solves: results.count,
                              generationSeconds: Date().timeIntervalSince(start))
    }

    /// Solves one random subgame and samples up to `decisionsPerSolve` decisions from it.
    static func generateSpot(index: Int, params: SuiteParameters) async throws -> [Decision] {
        try Task.checkCancellation()
        var rng = SeededRNG(seed: params.seed, stream: UInt64(index))
        let scenarios = params.scenarios
        let streets = params.streets.isEmpty ? [Street.river, .turn] : params.streets
        let scenario = scenarios[Int(rng.next() % UInt64(scenarios.count))]
        let root = streets[index % streets.count] // round-robin keeps the street mix balanced

        var deck = Card.deck
        deck.shuffle(using: &rng)
        let board = Array(deck.prefix(root.boardCount))
        let sub = subgame(scenario: scenario, root: root, board: board, rng: &rng)

        let solver = try GTOSolver(config: sub.config)
        _ = try await withTaskCancellationHandler {
            try await solver.solveAsync(maxIterations: params.maxIterations, targetExploitability: Float(params.targetExploitability))
        } onCancel: {
            solver.stop()
        }
        try Task.checkCancellation()
        let exploit = Double(solver.progress?.exploitability ?? 0)

        var cache: [[PathStep]: NodeInfo] = [:]
        func node(_ path: [PathStep]) async throws -> NodeInfo {
            if let n = cache[path] { return n }
            let n = try await solver.queryAsync(path)
            cache[path] = n
            return n
        }

        let rootNode = try await node([])
        var out: [Decision] = []
        var used = Set<String>()
        let attempts = params.decisionsPerSolve * 4
        for _ in 0..<attempts where out.count < params.decisionsPerSolve {
            try Task.checkCancellation()
            // Deal concrete hands from the (board-filtered) ranges, respecting card removal.
            let oopHands = rootNode.players[0].hands
            guard let oi = rng.weightedIndex(oopHands.map { Double($0.reach) }),
                  let oopCombo = Combo(oopHands[oi].combo) else { break }
            let ipHands = rootNode.players[1].hands
            let ipWeights = ipHands.map { h -> Double in
                guard let c = Combo(h.combo), !c.conflicts(with: oopCombo.cards) else { return 0 }
                return Double(h.reach)
            }
            guard let ii = rng.weightedIndex(ipWeights), let ipCombo = Combo(ipHands[ii].combo) else { break }
            let holes = [oopCombo, ipCombo]

            // Walk the tree following each hand's own GTO strategy.
            var path: [PathStep] = []
            var history = sub.history
            var candidates: [(NodeInfo, [PathStep], [HistoryEntry], HandInfo)] = []
            walk: while true {
                let n = try await node(path)
                switch n.kind {
                case .terminal:
                    break walk
                case .chance:
                    // Decisions are taken on the subgame's root street only, so `streets` controls the mix exactly.
                    break walk
                case .action:
                    guard let p = n.player,
                          let hand = n.players[p].hands.first(where: { Combo($0.combo)?.index == holes[p].index }) else { break walk }
                    let spread = Double((hand.actionEvs.max() ?? 0) - (hand.actionEvs.min() ?? 0))
                    if spread >= params.minEVSpread * Double(n.pot) {
                        candidates.append((n, path, history, hand))
                    }
                    guard let a = rng.weightedIndex(hand.strategy.map(Double.init)) else { break walk }
                    history.append(HistoryEntry(street: Street(rawValue: n.street) ?? root, seat: p,
                                                action: SpotAction(n.actions[a]), potBefore: Double(n.pot)))
                    path.append(.action(a))
                }
            }
            let fresh = candidates.filter { !used.contains("\($0.1)|\($0.3.combo)") }
            guard !fresh.isEmpty else { continue }
            let (n, p, h, hand) = fresh[Int(rng.next() % UInt64(fresh.count))]
            used.insert("\(p)|\(hand.combo)")
            let seat = n.player!
            let actions = n.actions.map { SpotAction($0) }
            out.append(Decision(
                id: "spot\(index)-\(out.count)", scenarioId: scenario.id, scenarioName: scenario.name,
                preflopSummary: scenario.summary, positions: [scenario.oopName, scenario.ipName], heroSeat: seat,
                street: Street(rawValue: n.street) ?? root, board: n.board, rootStreet: root,
                heroCards: holes[seat].description, villainCards: holes[1 - seat].description,
                flopPot: scenario.pot, subgamePot: Double(n.startingPot), pot: Double(n.pot),
                stacks: n.stacks.map(Double.init), toCall: actions.first { $0.kind == .call }?.amount ?? 0,
                history: h, actions: actions, strategy: hand.strategy.map(Double.init),
                actionEVs: hand.actionEvs.map(Double.init), equity: Double(hand.equity), exploitability: exploit,
                spotIndex: index))
        }
        return out
    }
}
