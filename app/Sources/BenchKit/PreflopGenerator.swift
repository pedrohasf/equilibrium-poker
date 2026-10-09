import Foundation
import SolverKit

/// Preflop suites (`--mode preflop`): heads-up preflop hands played with the preflop solver.
///
/// Design choice: preflop is its own suite type rather than the first street of hands-mode suites.
/// Chaining would require a fresh flop solve per preflop line with the solver's own reach as ranges
/// (the preset postflop scenarios use different sizes and ranges), which does not fit the time
/// budget. So per format we report **preflop bb/100** (these suites) and **postflop bb/100** (hands
/// suites) separately; `eqbench bench formats` shows both.
///
/// Each format has one or two (stack, ante) depths; each depth is solved once (≈ 2–4 s) and reused
/// for every hand. A hand deals both players a combo (card removal respected), then both sample
/// actions from their combo's GTO average strategy until the hand ends preflop (fold, all-in) or a
/// flop would be dealt; every decision is recorded (SB first action, BB response, SB vs 3-bet, …).
/// No triviality filter (`Decision.evSpreadPot` is stored). Seats: 0 = SB (the button, acts first
/// preflop), 1 = BB. Deep trees value flop terminals with the core's equity-realisation model.
extension SuiteGenerator {
    public struct PreflopSpec: Sendable, Hashable {
        public var stack: Double
        public var ante: Double
        public var summary: String
        public var format: GameFormat

        public var scenarioId: String { "hu-preflop-\(format.rawValue)-\(BB.fmt(stack))bb" }
        public var name: String { "Heads-up preflop · \(format.shortTitle) · \(BB.fmt(stack))bb" + (ante > 0 ? " + \(BB.fmt(ante))bb ante" : "") }
    }

    /// Depths per format: cash 100bb (no ante), MTT 40bb and 20bb (1bb BB ante), Spin 25bb and 15bb (no ante; picked per hand).
    public static func preflopSpecs(_ f: GameFormat) -> [PreflopSpec] {
        switch f {
        case .cash: return [PreflopSpec(stack: 100, ante: 0, summary: "6-max cash game, folded to the small blind: blind vs blind, 100bb.", format: f)]
        case .mtt40: return [PreflopSpec(stack: 40, ante: 1, summary: "Tournament, folded to the small blind: blind vs blind, 40bb, 1bb big-blind ante.", format: f)]
        case .mtt20: return [PreflopSpec(stack: 20, ante: 1, summary: "Tournament, folded to the small blind: blind vs blind, 20bb, 1bb big-blind ante.", format: f)]
        case .spin:
            return [PreflopSpec(stack: 25, ante: 0, summary: "Spin & Go 3-handed, the button folds: small blind vs big blind, 25bb.", format: f),
                    PreflopSpec(stack: 15, ante: 0, summary: "Spin & Go heads-up: the small blind is the button, 15bb.", format: f)]
        }
    }

    public struct PreflopProgress: Sendable {
        public var hands: Int
        public var total: Int
        public var decisions: Int
        public var elapsed: Double
        public var message: String?
    }

    /// Generates a preflop suite. `configOverride` (tests) replaces every depth's solver config.
    public static func generatePreflop(_ params: SuiteParameters, name: String? = nil, configOverride: PreflopConfig? = nil,
                                       progress: @escaping @Sendable (PreflopProgress) -> Void = { _ in }) async throws -> BenchmarkSuite {
        let start = Date()
        let format = params.gameFormat
        let specs = preflopSpecs(format)
        let total = max(1, params.hands ?? 200)

        // Solve each depth once.
        var solvers: [PreflopSolver] = []
        var records: [SolveRecord] = []
        for (i, spec) in specs.enumerated() {
            try Task.checkCancellation()
            let cfg = configOverride ?? PreflopConfig.standard(stack: spec.stack, ante: spec.ante)
            let t0 = Date()
            let solver = try PreflopSolver(config: cfg)
            let p = try await Task.detached(priority: .userInitiated) { try solver.solve() }.value
            let expl = Double(p.exploitability) / 1000 / (1.5 + spec.ante) * 100 // mbb/hand → % of the starting pot
            var rec = SolveRecord(index: i, scenarioId: spec.scenarioId, board: "", iterations: Int(p.iteration), exploitability: expl,
                                  solveSeconds: Date().timeIntervalSince(t0), sampleSeconds: 0, memoryBytes: 0, hands: 0, decisions: 0)
            rec.spr = spec.stack
            rec.tree = "preflop " + (cfg.openSizes.isEmpty && !cfg.allowLimp ? "push/fold" :
                "opens \(cfg.openSizes.map(BB.fmt).joined(separator: "/")), limp \(cfg.allowLimp ? "yes" : "no"), 3-bet ×\(cfg.threebet.map { String(format: "%g", $0) }.joined(separator: "/")), all-in")
                + String(format: " · %.2f mbb/hand", p.exploitability)
            records.append(rec)
            solvers.append(solver)
            progress(PreflopProgress(hands: 0, total: total, decisions: 0, elapsed: Date().timeIntervalSince(start),
                                     message: "solved \(spec.name) in \(String(format: "%.1f", rec.solveSeconds))s · \(rec.tree ?? "")"))
        }

        var rng = SeededRNG(seed: params.seed ^ 0x5052_4546, stream: 1)
        var caches = [[ [Int]: NodeInfo ]](repeating: [:], count: specs.count)
        var decisions: [Decision] = []
        let t1 = Date()
        for h in 0..<total {
            try Task.checkCancellation()
            let si = Int(rng.next() % UInt64(specs.count))
            let spec = specs[si], solver = solvers[si]
            func node(_ path: [Int]) throws -> NodeInfo {
                if let n = caches[si][path] { return n }
                let n = try solver.query(path)
                caches[si][path] = n
                return n
            }
            let root = try node([])
            let sbHands = root.players[0].hands
            guard let a = rng.weightedIndex(sbHands.map { Double($0.reach) }), let sb = Combo(sbHands[a].combo) else { break }
            let bbHands = root.players[1].hands
            let bbW = bbHands.map { x -> Double in
                guard let c = Combo(x.combo), !c.conflicts(with: sb.cards) else { return 0 }
                return Double(x.reach)
            }
            guard let b = rng.weightedIndex(bbW), let bb = Combo(bbHands[b].combo) else { break }
            let holes = [sb, bb]
            let handId = String(format: "h%03d", h + 1)
            var path: [Int] = []
            var history: [HistoryEntry] = []
            var seq = 0
            while true {
                let n = try node(path)
                guard n.kind == .action, let seat = n.player,
                      let hand = n.players[seat].hands.first(where: { Combo($0.combo)?.index == holes[seat].index }) else { break }
                let actions = n.actions.map { SpotAction(preflop: $0) }
                let spread = Double((hand.actionEvs.max() ?? 0) - (hand.actionEvs.min() ?? 0))
                if spread >= params.minEVSpread * Double(n.pot) {
                    var d = Decision(
                        id: "\(handId)-\(seq)", scenarioId: spec.scenarioId, scenarioName: spec.name, preflopSummary: spec.summary,
                        positions: ["SB", "BB"], heroSeat: seat, street: .preflop, board: [], rootStreet: .preflop,
                        heroCards: holes[seat].description, villainCards: holes[1 - seat].description,
                        flopPot: Double(n.startingPot), subgamePot: Double(n.startingPot), pot: Double(n.pot),
                        stacks: n.stacks.map(Double.init), toCall: actions.first { $0.kind == .call }?.amount ?? 0,
                        history: history, actions: actions, strategy: hand.strategy.map(Double.init),
                        actionEVs: hand.actionEvs.map(Double.init), equity: Double(hand.equity),
                        exploitability: records[si].exploitability, spotIndex: si)
                    d.handId = handId
                    d.handSeq = seq
                    d.formatId = format.rawValue
                    d.ante = spec.ante
                    decisions.append(d)
                    seq += 1
                }
                let w = hand.strategy.map { Double($0) >= minActionProbability ? Double($0) : 0 }
                guard let k = rng.weightedIndex(w) ?? rng.weightedIndex(hand.strategy.map(Double.init)) else { break }
                history.append(HistoryEntry(street: .preflop, seat: seat, action: actions[k], potBefore: Double(n.pot)))
                path.append(k)
            }
            records[si].hands += 1
            records[si].decisions += seq
            if (h + 1) % 25 == 0 || h + 1 == total {
                progress(PreflopProgress(hands: h + 1, total: total, decisions: decisions.count, elapsed: Date().timeIntervalSince(start)))
            }
        }
        let sampleSeconds = Date().timeIntervalSince(t1)
        for i in records.indices { records[i].sampleSeconds = sampleSeconds * Double(records[i].hands) / Double(max(1, total)) }

        let width = max(3, String(decisions.count).count)
        for i in decisions.indices { decisions[i].id = "d" + String(format: "%0\(width)d", i + 1) }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmmss"
        let id = "\(df.string(from: start))-preflop\(total)-\(format.rawValue)-n\(decisions.count)-s\(params.seed)"
        var suite = BenchmarkSuite(id: id, name: name ?? "\(format.shortTitle) · preflop · \(total) hands · \(decisions.count) decisions · seed \(params.seed)",
                                   createdAt: start, parameters: params, decisions: decisions, solves: records.count,
                                   generationSeconds: Date().timeIntervalSince(start))
        suite.solveRecords = records
        return suite
    }
}

extension SuiteParameters {
    /// Preflop-suite parameters (`hands` heads-up preflop hands of `format`).
    public static func preflop(_ hands: Int = 300, format: GameFormat = .cash, seed: UInt64 = 1, minEVSpread: Double = 0) -> SuiteParameters {
        var p = SuiteParameters(decisions: 0, streets: [.preflop], seed: seed, minEVSpread: minEVSpread, decisionsPerSolve: 0, concurrency: 1)
        p.mode = .preflop
        p.hands = hands
        p.format = format.rawValue
        return p
    }
}
