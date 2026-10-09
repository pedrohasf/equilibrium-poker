import Foundation
import SolverKit

/// Hands-mode suites: the realistic benchmark.
///
/// Each solve is a full **flop** game (the scenario's preflop ranges, a random flop, the lean
/// `HandsTreeConfig` tree). From each solve `handsPerSolve` concrete hands are dealt from the
/// ranges (card removal respected) and played to the end following the equilibrium: at every
/// action node the acting player samples an action from its own hand's GTO strategy, at chance
/// nodes the turn/river card is dealt uniformly from the cards neither player holds. **Every**
/// decision of both players on every street is recorded, grouped by `handId` and ordered by
/// `handSeq`, so turn and river spots see correctly narrowed ranges and the suite's street /
/// spot mix is the one GTO play actually produces. No triviality filter by default (`minEVSpread`
/// 0); `Decision.evSpreadPot` lets analyses filter afterwards.
///
/// Solves run sequentially (one flop solve already saturates every core); per-hand sampling
/// queries are cheap and run after each solve.
extension SuiteGenerator {
    /// Default scenario mix: weighted towards the most common heads-up postflop spots.
    public static let scenarioWeights: [String: Double] = [
        // cash
        "btn-bb-srp": 0.30, "co-bb-srp": 0.20, "sb-bb-srp": 0.12, "utg-bb-srp": 0.10,
        "btn-bb-3bp": 0.16, "co-btn-3bp": 0.12,
        // tournaments / spins (single-raised pots dominate at these depths)
        "mtt40-btn-bb-srp": 0.70, "mtt40-bb-btn-3bp": 0.30,
        "mtt20-btn-bb-srp": 0.60, "mtt20-sb-bb-srp": 0.40,
        "spin25-btn-bb-srp": 0.50, "spin15-hu-sb-bb": 0.50,
    ]

    /// Actions the solver plays less often than this are not sampled when walking a hand (their
    /// subtrees have ~zero reach, so solver values there are noise). The recorded strategy is untouched.
    static let minActionProbability = 0.002

    public struct HandsProgress: Sendable {
        public var solvesDone: Int
        public var solvesTotal: Int
        public var hands: Int
        public var decisions: Int
        public var elapsed: Double
        /// Seconds remaining, extrapolated from the mean solve time so far.
        public var eta: Double?
        public var last: SolveRecord?
    }

    /// Picks scenarios with `scenarioWeights` (uniform over the requested scenarios when unweighted).
    static func pickScenario(_ scenarios: [Scenario], rng: inout SeededRNG) -> Scenario {
        let w = scenarios.map { scenarioWeights[$0.id] ?? 0.1 }
        return scenarios[rng.weightedIndex(w) ?? 0]
    }

    /// Generates a hands-mode suite. Deterministic for a seed up to the multithreaded solver's
    /// floating-point noise. `scenariosOverride` is for tests (tiny ranges).
    public static func generateHands(_ params: SuiteParameters, name: String? = nil, scenariosOverride: [Scenario]? = nil,
                                     progress: @escaping @Sendable (HandsProgress) -> Void = { _ in }) async throws -> BenchmarkSuite {
        let start = Date()
        let perSolve = max(1, params.handsPerSolve ?? 3)
        let totalHands = max(1, params.hands ?? 120)
        let solves = (totalHands + perSolve - 1) / perSolve
        // The suite's format (default cash) unless scenarios are named explicitly.
        let scenarios = scenariosOverride ?? params.scenarios
        guard !scenarios.isEmpty else { throw BenchError("No scenarios for format \(params.gameFormat.rawValue)") }

        var decisions: [Decision] = []
        var records: [SolveRecord] = []
        var handCount = 0
        for i in 0..<solves {
            try Task.checkCancellation()
            let k = min(perSolve, totalHands - handCount)
            let (ds, rec) = try await solveAndPlay(index: i, hands: k, firstHand: handCount, params: params, scenarios: scenarios)
            decisions += ds
            records.append(rec)
            handCount += k
            let elapsed = Date().timeIntervalSince(start)
            let eta = elapsed / Double(i + 1) * Double(solves - i - 1)
            progress(HandsProgress(solvesDone: i + 1, solvesTotal: solves, hands: handCount, decisions: decisions.count,
                                   elapsed: elapsed, eta: eta, last: rec))
        }

        let width = max(3, String(decisions.count).count)
        for i in decisions.indices { decisions[i].id = "d" + String(format: "%0\(width)d", i + 1) }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = df.string(from: start)
        let fmt = params.gameFormat
        let id = "\(stamp)-hands\(handCount)-\(fmt.rawValue)-n\(decisions.count)-s\(params.seed)"
        var suite = BenchmarkSuite(id: id, name: name ?? "\(fmt.shortTitle) · \(handCount) hands · \(decisions.count) decisions · seed \(params.seed)",
                                   createdAt: start, parameters: params, decisions: decisions, solves: records.count,
                                   generationSeconds: Date().timeIntervalSince(start))
        suite.solveRecords = records
        return suite
    }

    /// Flop solver config for a scenario and board.
    public static func flopConfig(scenario: Scenario, board: [Card], tree: HandsTreeConfig) -> SolverConfig {
        SolverConfig(board: board.text, rangeOOP: scenario.rangeOOP, rangeIP: scenario.rangeIP,
                     startingPot: scenario.pot, effectiveStack: scenario.stack, betSizes: tree.betSizes,
                     allinThreshold: tree.allinThreshold, addAllin: tree.addAllin ?? false, raiseLimit: tree.raiseLimit)
    }

    /// One flop solve + `hands` GTO-played hands from it.
    static func solveAndPlay(index: Int, hands: Int, firstHand: Int, params: SuiteParameters,
                             scenarios: [Scenario]) async throws -> ([Decision], SolveRecord) {
        var rng = SeededRNG(seed: params.seed ^ 0x48414E44, stream: UInt64(index))
        let scenario = pickScenario(scenarios, rng: &rng)
        let tree = params.handsTree ?? .forSPR(scenario.stack / scenario.pot, targetExploitability: params.targetExploitability,
                                                maxIterations: params.maxIterations)
        var deck = Card.deck
        deck.shuffle(using: &rng)
        let flop = Array(deck.prefix(3))
        let cfg = flopConfig(scenario: scenario, board: flop, tree: tree)

        let t0 = Date()
        let solver = try GTOSolver(config: cfg)
        let p = try await withTaskCancellationHandler {
            try await solver.solveAsync(maxIterations: tree.maxIterations, targetExploitability: Float(tree.targetExploitability))
        } onCancel: {
            solver.stop()
        }
        try Task.checkCancellation()
        let solveSeconds = Date().timeIntervalSince(t0)
        let exploit = Double(p.exploitability)

        let t1 = Date()
        var cache: [[PathStep]: NodeInfo] = [:]
        func node(_ path: [PathStep]) async throws -> NodeInfo {
            if let n = cache[path] { return n }
            let n = try await solver.queryAsync(path)
            cache[path] = n
            return n
        }

        let root = try await node([])
        var out: [Decision] = []
        var played = 0
        for h in 0..<hands {
            try Task.checkCancellation()
            // Deal both hands from the board-filtered ranges, respecting card removal.
            let oopHands = root.players[0].hands
            guard let oi = rng.weightedIndex(oopHands.map { Double($0.reach) }), let oop = Combo(oopHands[oi].combo) else { break }
            let ipHands = root.players[1].hands
            let ipW = ipHands.map { x -> Double in
                guard let c = Combo(x.combo), !c.conflicts(with: oop.cards) else { return 0 }
                return Double(x.reach)
            }
            guard let ii = rng.weightedIndex(ipW), let ip = Combo(ipHands[ii].combo) else { break }
            let holes = [oop, ip]
            let handId = String(format: "h%03d", firstHand + h + 1)

            var path: [PathStep] = []
            var history: [HistoryEntry] = []
            var seq = 0
            walk: while true {
                let n = try await node(path)
                switch n.kind {
                case .terminal:
                    break walk
                case .chance:
                    let dead = Set(holes.flatMap(\.cards).map(\.description))
                    let cards = n.chanceCards.filter { !dead.contains($0) }
                    guard !cards.isEmpty else { break walk }
                    let card = cards[Int(rng.next() % UInt64(cards.count))]
                    let street = Street(boardCount: n.board.count + 1) ?? .river
                    history.append(HistoryEntry(street: street, seat: nil, action: nil, potBefore: Double(n.pot), card: card))
                    path.append(.card(card))
                case .action:
                    guard let seat = n.player,
                          let hand = n.players[seat].hands.first(where: { Combo($0.combo)?.index == holes[seat].index }) else { break walk }
                    let street = Street(rawValue: n.street) ?? .flop
                    let actions = n.actions.map { SpotAction($0) }
                    let spread = Double((hand.actionEvs.max() ?? 0) - (hand.actionEvs.min() ?? 0))
                    if spread >= params.minEVSpread * Double(n.pot) {
                        var d = Decision(
                            id: "\(handId)-\(seq)", scenarioId: scenario.id, scenarioName: scenario.name,
                            preflopSummary: scenario.summary, positions: [scenario.oopName, scenario.ipName], heroSeat: seat,
                            street: street, board: n.board, rootStreet: .flop,
                            heroCards: holes[seat].description, villainCards: holes[1 - seat].description,
                            flopPot: scenario.pot, subgamePot: Double(n.startingPot), pot: Double(n.pot),
                            stacks: n.stacks.map(Double.init), toCall: actions.first { $0.kind == .call }?.amount ?? 0,
                            history: history, actions: actions, strategy: hand.strategy.map(Double.init),
                            actionEVs: hand.actionEvs.map(Double.init), equity: Double(hand.equity), exploitability: exploit,
                            spotIndex: index)
                        d.handId = handId
                        d.handSeq = seq
                        d.formatId = scenario.format.rawValue
                        out.append(d)
                        seq += 1
                    }
                    let weights = hand.strategy.map { Double($0) >= minActionProbability ? Double($0) : 0 }
                    guard let a = rng.weightedIndex(weights) ?? rng.weightedIndex(hand.strategy.map(Double.init)) else { break walk }
                    history.append(HistoryEntry(street: street, seat: seat, action: actions[a], potBefore: Double(n.pot)))
                    path.append(.action(a))
                }
            }
            played += 1
        }
        var rec = SolveRecord(index: index, scenarioId: scenario.id, board: flop.text, iterations: Int(p.iteration),
                              exploitability: exploit, solveSeconds: solveSeconds, sampleSeconds: Date().timeIntervalSince(t1),
                              memoryBytes: solver.estimate.memoryBytes, hands: played, decisions: out.count)
        rec.spr = scenario.stack / scenario.pot
        rec.tree = tree.summary
        return (out, rec)
    }
}
