@testable import BenchKit
import OpenRouterKit
import SolverKit
import XCTest

final class BenchKitTests: XCTestCase {
    /// River decision facing a 5 bb bet into 10: fold / call / raise with EVs 0, 1, 3.
    func makeDecision(id: String = "d001", evs: [Double] = [0, 1, 3], strategy: [Double] = [0, 0.3, 0.7],
                      street: Street = .river) -> Decision {
        let actions = [
            SpotAction(kind: .fold, amount: 0, to: 0, potFraction: 0),
            SpotAction(kind: .call, amount: 5, to: 5, potFraction: 0),
            SpotAction(kind: .raise, amount: 15, to: 15, potFraction: 0.67),
        ]
        return Decision(id: id, scenarioId: "btn-bb-srp", scenarioName: "BTN vs BB", preflopSummary: "BTN opens 2.5bb, BB calls.",
                        positions: ["BB", "BTN"], heroSeat: 1, street: street, board: ["Qs", "Jh", "2h", "8d", "3c"],
                        rootStreet: street, heroCards: "AsKd", villainCards: "QhQd", flopPot: 5.5, subgamePot: 5, pot: 10,
                        stacks: [90, 95], toCall: 5,
                        history: [HistoryEntry(street: .river, seat: 0, action: SpotAction(kind: .bet, amount: 5, to: 5, potFraction: 1),
                                               potBefore: 5)],
                        actions: actions, strategy: strategy, actionEVs: evs, equity: 0.4, exploitability: 0.3, spotIndex: 0)
    }

    func testPerDecisionScoring() {
        let d = makeDecision()
        let best = Scoring.score(d, choice: 2)
        XCTAssertEqual(best.evLoss, 0)
        XCTAssertEqual(best.score, 1)
        XCTAssertTrue(best.isBest && best.approved && !best.blunder)

        let mid = Scoring.score(d, choice: 1)
        XCTAssertEqual(mid.evLoss, 2, accuracy: 1e-12)
        XCTAssertEqual(mid.evLossPot, 0.2, accuracy: 1e-12)
        XCTAssertEqual(mid.score, 1.0 / 3.0, accuracy: 1e-12)
        XCTAssertTrue(mid.approved) // GTO calls 30%
        XCTAssertFalse(mid.blunder)

        let worst = Scoring.score(d, choice: 0)
        XCTAssertEqual(worst.score, 0)
        XCTAssertTrue(worst.blunder) // 30% pot
        XCTAssertFalse(worst.approved)

        for bad in [nil, 7] as [Int?] {
            let inv = Scoring.score(d, choice: bad)
            XCTAssertFalse(inv.valid)
            XCTAssertEqual(inv.evLoss, 3)
            XCTAssertEqual(inv.score, 0)
        }

        // All actions equal: any choice is perfect.
        let flat = makeDecision(evs: [1, 1, 1])
        XCTAssertEqual(Scoring.score(flat, choice: 0).score, 1)
    }

    func testMeanCI() {
        XCTAssertEqual(Scoring.meanCI([]).mean, 0)
        XCTAssertEqual(Scoring.meanCI([4]).ci, 0)
        let (m, ci) = Scoring.meanCI([1, 2, 3, 4])
        XCTAssertEqual(m, 2.5)
        // sd = 1.29099, se = 0.645497, ci = 1.26517
        XCTAssertEqual(ci, 1.96 * (1.6666666666666667 / 4).squareRoot(), accuracy: 1e-12)
    }

    func testSummaryAndLeaderboard() {
        let ds = [makeDecision(id: "d001"), makeDecision(id: "d002", street: .turn)]
        let suite = BenchmarkSuite(id: "t", name: "t", parameters: SuiteParameters(decisions: 2), decisions: ds, solves: 1, generationSeconds: 0)
        var a = BenchmarkRun(suiteId: "t", model: "a/good", displayName: "a/good", kind: .decisionModel)
        a.results = [DecisionResult(decisionId: "d001", choice: 2, latency: 2, cost: 0.01),
                     DecisionResult(decisionId: "d002", choice: 1, latency: 4, cost: 0.02)]
        var b = BenchmarkRun(suiteId: "t", model: "b/bad", displayName: "b/bad", kind: .decisionModel)
        b.results = [DecisionResult(decisionId: "d001", choice: nil, error: "x")]

        let s = Scoring.summarize(a, suite: suite)
        XCTAssertEqual(s.answered, 2)
        XCTAssertTrue(s.isComplete)
        XCTAssertEqual(s.overall.gtoScore, (100 + 100.0 / 3) / 2, accuracy: 1e-9)
        XCTAssertEqual(s.overall.meanEVLoss, 1, accuracy: 1e-12)
        XCTAssertEqual(s.overall.accuracy, 0.5)
        XCTAssertEqual(s.meanLatency, 3)
        XCTAssertEqual(s.totalCost, 0.03, accuracy: 1e-12)
        XCTAssertEqual(s.byStreet["river"]?.gtoScore, 100)
        XCTAssertEqual(s.byStreet["turn"]?.n, 1)
        XCTAssertEqual(s.byType["facingBet"]?.n, 2)

        let sb = Scoring.summarize(b, suite: suite)
        XCTAssertFalse(sb.isComplete)
        XCTAssertEqual(sb.overall.invalidRate, 1)

        let board = Scoring.leaderboard(suite: suite, runs: [b, a])
        XCTAssertEqual(board.map(\.model), ["a/good", "b/bad"])
    }

    func testHistoryLines() {
        let d = makeDecision()
        let lines = d.historyLines()
        XCTAssertEqual(lines.count, 3) // flop, turn, river
        XCTAssertTrue(lines[0].hasPrefix("Flop Qs Jh 2h (pot 5.5 bb)"))
        XCTAssertTrue(lines[2].contains("BB bets 5 bb (100% pot)"))
        XCTAssertTrue(d.historyLines(names: ["OOP", "IP"])[2].contains("OOP bets"))
        XCTAssertFalse(lines.joined().contains("QhQd"), "villain's cards must never leak")
    }

    func testBaselinesAreDeterministic() {
        let d = makeDecision()
        XCTAssertEqual(Baseline.bestEV.choose(d), 2)
        XCTAssertEqual(Baseline.callingStation.choose(d), 1)
        XCTAssertEqual(Baseline.random.choose(d), Baseline.random.choose(d))
        XCTAssertNotEqual(Baseline.gto.choose(d), 0) // fold has 0% frequency
        XCTAssertEqual(Baseline(id: "baseline:gto"), .gto)
    }

    func testSeededRNG() {
        var a = SeededRNG(seed: 42, stream: 3), b = SeededRNG(seed: 42, stream: 3), c = SeededRNG(seed: 42, stream: 4)
        let xa = (0..<5).map { _ in a.next() }
        XCTAssertEqual(xa, (0..<5).map { _ in b.next() })
        XCTAssertNotEqual(xa, (0..<5).map { _ in c.next() })
        var r = SeededRNG(seed: 1)
        XCTAssertNil(r.weightedIndex([0.0, 0.0]))
        XCTAssertEqual(r.weightedIndex([0.0, 1.0, 0.0]), 1)
    }

    /// End-to-end: solve a couple of river spots and check the baselines calibrate the scale.
    func testGenerateAndRunBaselines() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("benchkit-\(UUID().uuidString)")
        BenchStore.rootOverride = dir
        defer {
            BenchStore.rootOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        let params = SuiteParameters(decisions: 4, streets: [.river], scenarioIds: ["btn-bb-srp"], seed: 3, decisionsPerSolve: 2)
        let suite = try await SuiteGenerator.generate(params)
        XCTAssertEqual(suite.decisions.count, 4)
        for d in suite.decisions {
            XCTAssertEqual(d.street, .river)
            XCTAssertEqual(d.board.count, 5)
            XCTAssertEqual(d.actions.count, d.strategy.count)
            XCTAssertEqual(d.actions.count, d.actionEVs.count)
            XCTAssertEqual(d.strategy.reduce(0, +), 1, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(d.evSpread, params.minEVSpread * d.pot)
            XCTAssertFalse(Set(d.heroCardList).intersection(d.boardCards).count > 0)
        }
        try BenchStore.save(suite)
        XCTAssertEqual(try BenchStore.loadSuite(suite.id).decisions, suite.decisions)

        let runs = try await BenchmarkRunner.run(suite: suite, players: Baseline.allCases, concurrency: 4)
        let rows = Scoring.leaderboard(suite: suite, runs: runs)
        let best = rows.first { $0.model == "baseline:bestEV" }!
        XCTAssertEqual(best.overall.gtoScore, 100, accuracy: 1e-9)
        XCTAssertEqual(best.overall.meanEVLoss, 0, accuracy: 1e-9)
        let gto = rows.first { $0.model == "baseline:gto" }!
        XCTAssertGreaterThan(gto.overall.gtoScore, 90)
        XCTAssertEqual(BenchStore.runs(suiteId: suite.id).count, 4)

        // Resuming answers nothing new.
        let again = try await BenchmarkRunner.run(suite: suite, players: [Baseline.random])
        XCTAssertEqual(again[0].results.count, 4)
    }

    /// A scripted decision model that answers from a fixed key per decision (nil = failure).
    struct ScriptedModel: DecisionMaker {
        let pick: @Sendable (Decision) -> Int?
        var id: String { "mock/scripted" }
        var displayName: String { "Scripted" }
        var kind: PlayerKind { .decisionModel }
        func decide(_ d: Decision) async throws -> DecisionResult {
            let c = pick(d)
            return DecisionResult(decisionId: d.id, choice: c, error: c == nil ? "no choice" : nil, latency: 1,
                                  promptTokens: 500, cost: 0.001,
                                  actionProbabilities: c.map { i in d.actions.indices.map { $0 == i ? 1 : 0 } })
        }
    }

    func testRunnerWithScriptedModel() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("benchkit-\(UUID().uuidString)")
        BenchStore.rootOverride = dir
        defer {
            BenchStore.rootOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        let ds = [makeDecision(id: "d001"), makeDecision(id: "d002"), makeDecision(id: "d003")]
        let suite = BenchmarkSuite(id: "mock", name: "mock", parameters: SuiteParameters(decisions: 3), decisions: ds, solves: 1, generationSeconds: 0)
        let player = ScriptedModel { d in
            switch d.id {
            case "d001": return 2
            case "d002": return 1
            default: return nil
            }
        }
        let runs = try await BenchmarkRunner.run(suite: suite, players: [player], concurrency: 2)
        let row = Scoring.summarize(runs[0], suite: suite)
        XCTAssertEqual(row.answered, 3)
        XCTAssertEqual(row.overall.invalidRate, 1.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(row.overall.gtoScore, (100 + 100.0 / 3 + 0) / 3, accuracy: 1e-9)
        XCTAssertEqual(row.overall.distributionN, 3)
        XCTAssertEqual(row.totalCost, 0.003, accuracy: 1e-12)
        XCTAssertEqual(runs[0].id, BenchmarkRun.makeId(suiteId: "mock", model: "mock/scripted"))
        XCTAssertNotNil(BenchStore.loadRun(id: runs[0].id))

        // Old chat-LLM run files (kind "llm", chat options) are skipped, not fatal.
        let legacy = #"{"id":"mock__openai_gpt-5","suiteId":"mock","model":"openai/gpt-5","displayName":"openai/gpt-5","kind":"llm","options":{"reasoningEffort":"low","jsonMode":false},"promptVersion":1,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","results":[]}"#
        try Data(legacy.utf8).write(to: BenchStore.url(run: "mock__openai_gpt-5"))
        XCTAssertEqual(BenchStore.runs(suiteId: "mock").map(\.model), ["mock/scripted"])
        XCTAssertNil(BenchStore.loadRun(id: "mock__openai_gpt-5"))
    }

    // MARK: - Decision models

    /// Records requests and replies with a canned `DecideResult` (or throws).
    final class MockDecisionProvider: DecisionProvider, @unchecked Sendable {
        let reply: @Sendable (Decision?, [String: DecisionQuestion]) throws -> DecideResult
        let lock = NSLock()
        var requests: [(model: String, state: JSONValue, questions: [String: DecisionQuestion])] = []
        let decisions: [Decision]

        init(decisions: [Decision], reply: @escaping @Sendable (Decision?, [String: DecisionQuestion]) throws -> DecideResult) {
            self.decisions = decisions
            self.reply = reply
        }

        func decide(model: String, state: JSONValue, questions: [String: DecisionQuestion]) async throws -> DecideResult {
            lock.withLock { requests.append((model, state, questions)) }
            // Identify the decision from the state's hole cards (the mock never sees ids).
            let d = decisions.first { DecisionStateBuilder.state($0) == state }
            return try reply(d, questions)
        }
    }

    static func choice(_ key: String, _ probs: [String: Double], confidence: Double? = 0.6, cost: Double = 0.0002) -> DecideResult {
        DecideResult(model: "mock/dm", answers: ["action": .choice(choice: key, confidence: confidence, probabilities: probs)],
                     usage: APIUsage(promptTokens: 900, cost: cost), latency: 0.4, raw: "{\"answers\":{}}")
    }

    func testDecisionStateAndQuestion() {
        let d = makeDecision()
        XCTAssertEqual(DecisionStateBuilder.actionKeys(d.actions), ["fold", "call", "raise_to_15bb"])
        guard case .choice(let instructions, let criteria) = DecisionStateBuilder.question(d) else { return XCTFail() }
        XCTAssertTrue(instructions.contains("game-theory-optimal"))
        XCTAssertEqual(Set(criteria.keys), ["fold", "call", "raise_to_15bb"])
        XCTAssertTrue(criteria["call"]!.contains("Call 5 bb"))
        XCTAssertTrue(criteria["call"]!.contains("33%")) // 5 / (10 + 5)
        let text = DecisionStateBuilder.requestBody(d).prettyText
        XCTAssertTrue(text.contains("\"hole_cards\" : \"As Kd\""))
        XCTAssertTrue(text.contains("Ace of spades and King of diamonds"))
        XCTAssertTrue(text.contains("BB (villain) bets 5 bb (100% pot)"))
        XCTAssertTrue(text.contains("\"in_position\" : true"))
        XCTAssertTrue(text.contains("\"equity_needed_to_call_pct\" : 33.3"))
        XCTAssertTrue(text.contains("no pair, ace high"))
        XCTAssertFalse(text.contains("QhQd") || text.contains("Qh Qd"), "villain's cards must never leak")
        XCTAssertFalse(text.contains("\"equity\""), "solver equity must not leak")

        // Duplicate sizes stay unique; decimals become underscores.
        let acts = [SpotAction(kind: .check, amount: 0, to: 0, potFraction: 0),
                    SpotAction(kind: .bet, amount: 3.3, to: 3.3, potFraction: 0.33),
                    SpotAction(kind: .bet, amount: 3.4, to: 3.4, potFraction: 0.334),
                    SpotAction(kind: .raise, amount: 12.5, to: 12.5, potFraction: 0.5),
                    SpotAction(kind: .allin, amount: 90, to: 90, potFraction: 9)]
        XCTAssertEqual(DecisionStateBuilder.actionKeys(acts), ["check", "bet_33pct_pot", "bet_33pct_pot_2", "raise_to_12_5bb", "allin"])
        XCTAssertEqual(DecisionStateBuilder.actionIndex(forKey: " Raise_To_12_5BB ", actions: acts), 3)
        XCTAssertNil(DecisionStateBuilder.actionIndex(forKey: "jam", actions: acts))
    }

    func testDecisionModelMapping() async throws {
        let d = makeDecision()
        let provider = MockDecisionProvider(decisions: [d]) { _, q in
            XCTAssertNotNil(q["action"])
            // Unnormalised, with an unknown key that must be dropped.
            return Self.choice("raise_to_15bb", ["fold": 0, "call": 1, "raise_to_15bb": 3, "bogus": 5], confidence: 0.75)
        }
        let maker = DecisionModelMaker(model: "typesafe/jev-1.13", provider: provider)
        XCTAssertEqual(maker.kind, .decisionModel)
        let r = try await maker.decide(d)
        XCTAssertEqual(r.choice, 2)
        XCTAssertEqual(r.actionProbabilities!, [0, 0.25, 0.75])
        XCTAssertEqual(r.confidence, 0.75)
        XCTAssertEqual(r.promptTokens, 900)
        XCTAssertEqual(r.cost, 0.0002)
        XCTAssertEqual(r.latency, 0.4)
        XCTAssertNil(r.error)
        XCTAssertEqual(provider.requests.first?.model, "typesafe/jev-1.13")

        // Missing probabilities → one-hot on the choice.
        let oneHot = DecisionModelMaker.result(Self.choice("call", [:]), decision: d)
        XCTAssertEqual(oneHot.actionProbabilities!, [0, 1, 0])

        // Unknown key → invalid, scored as worst.
        let unknown = DecisionModelMaker.result(Self.choice("check", ["check": 1]), decision: d)
        XCTAssertNil(unknown.choice)
        XCTAssertNil(unknown.actionProbabilities)
        XCTAssertTrue(unknown.error!.contains("check"))

        // No choice answer → invalid; provider error → invalid (not thrown).
        let none = DecisionModelMaker.result(DecideResult(model: "m", answers: [:]), decision: d)
        XCTAssertNil(none.choice)
        let failing = DecisionModelMaker(model: "x/y", provider: MockDecisionProvider(decisions: [d]) { _, _ in
            throw BenchError("bad request")
        })
        let failed = try await failing.decide(d)
        XCTAssertNil(failed.choice)
        XCTAssertNotNil(failed.error)
    }

    func testDistributionScoring() {
        let d = makeDecision() // EVs 0, 1, 3 · strategy 0, .3, .7 · pot 10
        XCTAssertEqual(Scoring.normalized([1, 3, -2, .nan]), [0.25, 0.75, 0, 0])
        XCTAssertNil(Scoring.normalized([0, 0]))

        let p = [0.1, 0.2, 0.7]
        // loss = [3, 2, 0] → 0.3 + 0.4 = 0.7 bb
        XCTAssertEqual(Scoring.mixedEVLoss(d, probabilities: p), 0.7, accuracy: 1e-12)
        // ½(|.1−0| + |.2−.3| + |.7−.7|) = 0.1
        XCTAssertEqual(Scoring.totalVariation(p, d.strategy), 0.1, accuracy: 1e-12)
        XCTAssertEqual(Scoring.totalVariation([1, 0], [0, 1]), 1)
        XCTAssertEqual(Scoring.bestActionProbability(d, probabilities: p), 0.7, accuracy: 1e-12)

        let s = Scoring.score(d, choice: 2, probabilities: [1, 2, 7], confidence: 0.5) // unnormalised input
        XCTAssertEqual(s.evLoss, 0)
        XCTAssertEqual(s.mixedEVLoss!, 0.7, accuracy: 1e-12)
        XCTAssertEqual(s.mixedEVLossPot!, 0.07, accuracy: 1e-12)
        XCTAssertEqual(s.tvDistance!, 0.1, accuracy: 1e-12)
        XCTAssertEqual(s.confidence, 0.5)

        // A probabilistic player's invalid answer is the worst distribution.
        let inv = Scoring.score(d, choice: nil, probabilistic: true)
        XCTAssertEqual(inv.mixedEVLoss, 3)
        XCTAssertEqual(inv.tvDistance, 1)
        XCTAssertEqual(inv.bestActionProbability, 0)
        // Argmax-only players have no distribution metrics.
        XCTAssertNil(Scoring.score(d, choice: 1).mixedEVLoss)

        // Buckets average only decisions with distributions.
        let b = Scoring.bucket([s, inv, Scoring.score(d, choice: 1)])
        XCTAssertEqual(b.distributionN, 2)
        XCTAssertEqual(b.meanMixedEVLoss!, (0.7 + 3) / 2, accuracy: 1e-12)
        XCTAssertEqual(b.meanTVDistance!, 0.55, accuracy: 1e-12)
        XCTAssertEqual(b.meanBestActionProbability!, 0.35, accuracy: 1e-12)
        XCTAssertNil(Scoring.bucket([Scoring.score(d, choice: 1)]).meanMixedEVLoss)
    }

    func testDecisionModelRunAndLeaderboard() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("benchkit-\(UUID().uuidString)")
        BenchStore.rootOverride = dir
        defer {
            BenchStore.rootOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        let ds = [makeDecision(id: "d001"), makeDecision(id: "d002", street: .turn)]
        let suite = BenchmarkSuite(id: "dm", name: "dm", parameters: SuiteParameters(decisions: 2), decisions: ds, solves: 1, generationSeconds: 0)
        let provider = MockDecisionProvider(decisions: ds) { d, _ in
            d?.street == .turn ? Self.choice("nonsense", [:]) : Self.choice("call", ["call": 0.6, "raise_to_15bb": 0.4])
        }
        let players: [any DecisionMaker] = [DecisionModelMaker(model: "typesafe/jev-1.13", provider: provider), Baseline.gto, Baseline.bestEV]
        let runs = try await BenchmarkRunner.run(suite: suite, players: players, concurrency: 2)
        let dmRun = runs[0]
        XCTAssertEqual(dmRun.kind, .decisionModel)
        XCTAssertEqual(dmRun.stateVersion, DecisionStateBuilder.version)
        XCTAssertNil(runs[1].stateVersion)

        let rows = Scoring.leaderboard(suite: suite, runs: runs)
        let dm = rows.first { $0.isDecisionModel }!
        XCTAssertEqual(dm.overall.invalidRate, 0.5)
        XCTAssertEqual(dm.overall.distributionN, 2)
        // d001: 0.6·2 + 0.4·0 = 1.2 bb; d002 invalid: spread 3 bb.
        XCTAssertEqual(dm.overall.meanMixedEVLoss!, (1.2 + 3) / 2, accuracy: 1e-12)
        // d001: ½(0 + .3 + .3) = 0.3; invalid: 1.
        XCTAssertEqual(dm.overall.meanTVDistance!, 0.65, accuracy: 1e-12)
        XCTAssertEqual(dm.overall.meanConfidence!, 0.6, accuracy: 1e-12)
        XCTAssertEqual(dm.totalCost, 0.0004, accuracy: 1e-12)

        // Sampled GTO is scored on its strategy: TV distance 0.
        let gto = rows.first { $0.model == Baseline.gto.id }!
        XCTAssertEqual(gto.overall.meanTVDistance!, 0, accuracy: 1e-12)
        XCTAssertEqual(gto.overall.meanMixedEVLoss!, 0.6, accuracy: 1e-12) // 0.3 · 2
        XCTAssertFalse(rows.first { $0.model == Baseline.bestEV.id }!.hasDistribution)

        // Saved runs round-trip with the new fields; old runs without them still decode.
        let loaded = BenchStore.loadRun(id: dmRun.id)!
        XCTAssertEqual(loaded.result(for: "d001")?.actionProbabilities, [0, 0.6, 0.4])
        let legacy = #"{"decisionId":"d001","choice":1,"latency":0,"promptTokens":0,"completionTokens":0,"reasoningTokens":0,"cost":0,"answeredAt":"2026-01-01T00:00:00Z"}"#
        let old = try Storage.decoder.decode(DecisionResult.self, from: Data(legacy.utf8))
        XCTAssertNil(old.actionProbabilities)
        XCTAssertNil(old.confidence)

        let text = BenchCLI.leaderboardText(suite: suite, rows: rows)
        XCTAssertTrue(text.contains("Decision models (1)"))
        XCTAssertTrue(text.contains("Baselines (2)"))
        XCTAssertTrue(text.contains("Mixed %pot"))
    }

    func testModelResolution() throws {
        let catalog: Set<String> = ["typesafe/jev-1.13", "liquid/d1"]
        XCTAssertEqual(try BenchCLI.resolveModels(["typesafe/jev-1.13", "dm:liquid/d1", "liquid/d1"], decisionCatalog: catalog),
                       ["typesafe/jev-1.13", "liquid/d1"])
        XCTAssertThrowsError(try BenchCLI.resolveModels(["typesafe/jev-1.13", "openai/gpt-5"], decisionCatalog: catalog)) { e in
            let msg = e.localizedDescription
            XCTAssertTrue(msg.contains("openai/gpt-5"))
            XCTAssertTrue(msg.contains("liquid/d1"), "lists the available decision models")
            XCTAssertFalse(msg.contains("typesafe/jev-1.13, openai"), "only unknown ids are reported as unknown")
        }
        XCTAssertThrowsError(try BenchCLI.resolveModels(["dm:new/model"], decisionCatalog: catalog))
    }

    // MARK: - Hands suites, variants, post-hoc players

    /// Two hands: h1 = d001 (seat 1) + d002 (seat 0), h2 = d003 (seat 1).
    func handsSuite() -> BenchmarkSuite {
        var a = makeDecision(id: "d001"), b = makeDecision(id: "d002", street: .turn), c = makeDecision(id: "d003")
        b.heroSeat = 0
        a.handId = "h001"; a.handSeq = 0
        b.handId = "h001"; b.handSeq = 1
        c.handId = "h002"; c.handSeq = 0
        let p = SuiteParameters.hands(2, handsPerSolve: 2)
        return BenchmarkSuite(id: "hs", name: "hs", parameters: p, decisions: [a, b, c], solves: 1, generationSeconds: 0)
    }

    func run(_ model: String, _ choices: [String: Int?], probs: [String: [Double]] = [:], variant: String? = nil) -> BenchmarkRun {
        var r = BenchmarkRun(suiteId: "hs", model: model, displayName: model, kind: .decisionModel, variant: variant)
        r.results = choices.sorted { $0.key < $1.key }.map { id, c in
            DecisionResult(decisionId: id, choice: c, actionProbabilities: probs[id] ?? c.map { i in (0..<3).map { $0 == i ? 1 : 0 } })
        }
        return r
    }

    func testHandMetricsBbPer100() {
        let suite = handsSuite()
        XCTAssertTrue(suite.isHands)
        XCTAssertEqual(suite.handIds, ["h001", "h002"])
        // EVs [0, 1, 3]: losses call 2, fold 3, raise 0.
        let r = run("m/a", ["d001": 1, "d002": 0, "d003": 2], probs: ["d001": [0, 0.5, 0.5]])
        let m = Scoring.summarize(r, suite: suite).perHand!
        // h1: (2 + 3) / 2 = 2.5 bb per seat-hand; h2: 0 → mean 1.25 bb → 125 bb/100.
        XCTAssertEqual(m.hands, 2)
        XCTAssertEqual(m.bbPer100, 125, accuracy: 1e-9)
        XCTAssertEqual(m.bbPer100CI, 1.96 * (Scoring.meanCI([250, 0]).ci / 1.96), accuracy: 1e-9)
        // Mixed: d001 0.5·2 = 1, d002 one-hot fold 3, d003 0 → h1 4/2 = 2, h2 0 → 100.
        XCTAssertEqual(m.mixedBbPer100!, 100, accuracy: 1e-9)
        XCTAssertEqual(m.bySeat["IP"]!, 100 * (2 + 0) / 2, accuracy: 1e-9)
        XCTAssertEqual(m.bySeat["OOP"]!, 100 * 3 / 2, accuracy: 1e-9)
        // Incomplete hands are excluded.
        let partial = run("m/b", ["d001": 1, "d003": 2])
        XCTAssertEqual(Scoring.summarize(partial, suite: suite).perHand!.hands, 1)
        // Spot suites have no per-hand metrics.
        let spots = BenchmarkSuite(id: "hs", name: "s", parameters: SuiteParameters(decisions: 3), decisions: suite.decisions, solves: 1, generationSeconds: 0)
        XCTAssertNil(Scoring.summarize(r, suite: spots).perHand)
        let text = BenchCLI.leaderboardText(suite: suite, rows: Scoring.leaderboard(suite: suite, runs: [r]))
        XCTAssertTrue(text.contains("bb/100 lost"))
    }

    func testPairedComparison() {
        let suite = handsSuite()
        let good = run("m/good", ["d001": 2, "d002": 2, "d003": 2])
        let bad = run("m/bad", ["d001": 1, "d002": 0, "d003": 2])
        let p = Scoring.paired(good, bad, suite: suite)
        XCTAssertEqual(p.score.n, 3)
        // Scores good 100,100,100 vs bad 33.3, 0, 100 → diffs 66.7, 100, 0.
        XCTAssertEqual(p.score.mean, (200.0 / 3 + 100) / 3, accuracy: 1e-9)
        // bb/100 per hand: h1 good 0 vs bad 250 → −250; h2 0.
        XCTAssertEqual(p.bbPer100!.mean, -125, accuracy: 1e-9)
        XCTAssertEqual(p.bbPer100!.n, 2)
        let text = BenchCLI.compareText(suite: suite, runs: [good, bad], reference: bad)
        XCTAssertTrue(text.contains("(ref)"))
        XCTAssertTrue(text.contains("m/good [v2]"))
    }

    func testVariantRunIdsAndLabels() {
        XCTAssertEqual(BenchmarkRun.makeId(suiteId: "s", model: "a/b", variant: "v2"), BenchmarkRun.makeId(suiteId: "s", model: "a/b"))
        XCTAssertEqual(BenchmarkRun.makeId(suiteId: "s", model: "a/b", variant: "eq"), "s__a_b__eq")
        let r = BenchmarkRun(suiteId: "s", model: "a/b", displayName: "a/b", kind: .decisionModel, variant: "eq")
        XCTAssertEqual(r.label, "a/b [eq]")
        XCTAssertEqual(BenchmarkRun(suiteId: "s", model: "a/b", displayName: "a/b", kind: .decisionModel).label, "a/b [v2]")
        XCTAssertEqual(BenchmarkRun(suiteId: "s", model: "baseline:gto", displayName: "GTO", kind: .baseline).label, "GTO")
        XCTAssertNotNil(try? BenchCLI.resolveVariants(["eq", "noul"]))
        XCTAssertThrowsError(try BenchCLI.resolveVariants(["nope"]))
        XCTAssertEqual(try BenchCLI.findRun("a/b [eq]", in: [r]).id, r.id)
    }

    func testEveryVariantKeepsActionKeys() {
        let d = makeDecision()
        let keys = Set(DecisionStateBuilder.actionKeys(d.actions))
        XCTAssertEqual(Set(DecisionVariants.ids), ["v2", "minimal", "eq", "eqrange", "coach", "multi", "noul", "nuts", "shortstack"])
        for v in DecisionVariants.all {
            let (state, qs) = v.build(d)
            XCTAssertFalse(qs.isEmpty, v.id)
            let text = v.requestBody(d).prettyText
            XCTAssertFalse(text.contains("QhQd") || text.contains("Qh Qd"), "\(v.id) leaks villain cards")
            XCTAssertFalse(text.contains("\"equity\" :"), "\(v.id) leaks solver equity")
            XCTAssertNotEqual(state, .null)
            for (id, q) in qs {
                switch q {
                case .choice(_, let c): XCTAssertEqual(Set(c.keys), keys, "\(v.id).\(id)")
                case .noul: XCTAssertTrue(id.hasPrefix(DecisionVariants.noulPrefix) && keys.contains(String(id.dropFirst(5))), id)
                case .score: XCTFail("unexpected score question")
                }
            }
        }
        XCTAssertEqual(DecisionVariants.v2.build(d).state, DecisionStateBuilder.state(d), "v2 is the legacy state")
        // eq adds Monte-Carlo equity vs the villain's preflop range.
        let eq = DecisionVariants.eq.requestBody(d).prettyText
        XCTAssertTrue(eq.contains("equity_vs_villain_preflop_range_pct"))
        XCTAssertTrue(eq.contains("needed to call"))
        XCTAssertTrue(DecisionVariants.eqrange.requestBody(d).prettyText.contains("equity_vs_villain_likely_range_pct"))
        XCTAssertFalse(DecisionVariants.minimal.requestBody(d).prettyText.contains("made_hand"))
        XCTAssertEqual(DecisionVariants.multi.build(d).questions.count, 3)
        XCTAssertEqual(DecisionVariants.noul.build(d).questions.count, 3)
    }

    func testMultiAndNoulInterpretation() {
        let d = makeDecision()
        let multi = DecideResult(model: "m", answers: [
            "action": .choice(choice: "call", confidence: 0.5, probabilities: ["call": 0.6, "raise_to_15bb": 0.4]),
            "action_coach": .choice(choice: "raise_to_15bb", confidence: 0.7, probabilities: ["raise_to_15bb": 1]),
            "action_solver": .choice(choice: "bogus", confidence: 0.9, probabilities: [:]),
        ], usage: APIUsage(promptTokens: 100, cost: 0.001))
        let r = DecisionVariants.multi.interpret(multi, d)
        XCTAssertEqual(r.actionProbabilities!, [0, 0.3, 0.7])
        XCTAssertEqual(r.choice, 2)
        XCTAssertEqual(r.confidence!, 0.6, accuracy: 1e-12)
        XCTAssertEqual(r.parts?.count, 3)
        XCTAssertNil(r.parts?[2].probabilities)
        XCTAssertEqual(r.cost, 0.001)
        XCTAssertNil(DecisionVariants.multi.interpret(DecideResult(model: "m", answers: [:]), d).choice)

        let noul = DecideResult(model: "m", answers: ["best_fold": .noul(probability: 0.1), "best_call": .noul(probability: 0.3),
                                                      "best_raise_to_15bb": .noul(probability: 0.6)])
        let n = DecisionVariants.noul.interpret(noul, d)
        XCTAssertEqual(n.choice, 2)
        XCTAssertEqual(n.actionProbabilities![0], 0.1, accuracy: 1e-12)
        XCTAssertEqual(n.actionProbabilities![2], 0.6, accuracy: 1e-12)
        XCTAssertEqual(n.parts?.map(\.pTrue), [0.1, 0.3, 0.6])
        let missing = DecisionVariants.noul.interpret(DecideResult(model: "m", answers: ["best_fold": .noul(probability: 0.1)]), d)
        XCTAssertNil(missing.choice)
        XCTAssertNotNil(missing.error)
    }

    func testSynthMath() throws {
        XCTAssertEqual(Synth.average([[1, 0, 0], [0, 2, 2]])!, [0.5, 0.25, 0.25])
        XCTAssertEqual(Synth.average([[1, 0], [0, 1]], weights: [3, 1])!, [0.75, 0.25])
        XCTAssertNil(Synth.average([[0, 0]]))
        let t = Synth.temper([0.2, 0.8], tau: 2)
        XCTAssertEqual(t[1], 0.64 / 0.68, accuracy: 1e-12)
        XCTAssertEqual(Synth.temper([0.2, 0.8], tau: 1), [0.2, 0.8])
        XCTAssertEqual(Synth.temper([0.3, 0.7, 0], tau: .infinity), [0, 1, 0])
        XCTAssertEqual(Synth.temper([0.5, 0.25, 0.25], tau: 0.5)[0], 0.5.squareRoot() / (0.5.squareRoot() + 2 * 0.25.squareRoot()), accuracy: 1e-12)

        let d = makeDecision() // facing 5 into 10: needs 33%
        let g = Synth.foldGuard([0.7, 0.2, 0.1], decision: d, equity: 0.45, margin: 0.05)
        XCTAssertTrue(g.fired)
        XCTAssertEqual(g.p[0], 0)
        XCTAssertEqual(g.p[1], 0.9, accuracy: 1e-12)
        XCTAssertFalse(Synth.foldGuard([0.7, 0.2, 0.1], decision: d, equity: 0.35, margin: 0.05).fired)

        let suite = handsSuite()
        let a = run("m/a", ["d001": 1, "d002": 0, "d003": 2], probs: ["d001": [0, 0.8, 0.2]])
        let b = run("m/b", ["d001": 2, "d002": nil, "d003": 2], probs: ["d001": [0, 0.2, 0.8]])
        let e = try Synth.ensemble([a, b], weights: [1, 3], suite: suite)
        XCTAssertEqual(e.kind, .derived)
        XCTAssertEqual(e.results.count, 3)
        let r1 = e.result(for: "d001")!
        XCTAssertEqual(r1.actionProbabilities![2], (0.2 + 3 * 0.8) / 4, accuracy: 1e-12)
        XCTAssertEqual(r1.choice, 2)
        XCTAssertEqual(e.result(for: "d002")!.choice, 0, "invalid member skipped")
        XCTAssertTrue(Scoring.summarize(e, suite: suite).hasDistribution)

        let sharp = Synth.temper(a, tau: .infinity, suite: suite)
        XCTAssertEqual(sharp.result(for: "d001")!.actionProbabilities!, [0, 1, 0])
        XCTAssertEqual(sharp.derived?.method, "temper")
        XCTAssertNotEqual(sharp.id, a.id)
        XCTAssertThrowsError(try Synth.ensemble([a], suite: suite))
    }

    func testEquityToolsHeuristics() throws {
        XCTAssertEqual(EquityTools.valueFraction(sizePot: 0.33, isRaise: false), 0.5)
        XCTAssertEqual(EquityTools.valueFraction(sizePot: 0.75, isRaise: true), 0.2)
        // River 75% pot with 40% value: bluffs = 30% of the betting range.
        let b = EquityTools.bluffWeight(sizePot: 0.75, valueFraction: 0.4, river: true)
        XCTAssertEqual(b * 0.6 / (0.4 + b * 0.6), 0.3, accuracy: 1e-9)
        let d = makeDecision()
        let f = try XCTUnwrap(EquityTools.facts(d))
        XCTAssertTrue((0...1).contains(f.equityPreflop) && (0...1).contains(f.equityNarrowed))
        XCTAssertLessThan(f.narrowedCombos, f.preflopCombos, "a river bet narrows the range")
        XCTAssertLessThan(f.equityNarrowed, f.equityPreflop, "AK-high is worse vs a betting range")
        XCTAssertEqual(EquityTools.facts(d), f, "deterministic / cached")
    }

    func testSplitSuite() {
        let suite = handsSuite()
        let (dev, test) = BenchCLI.splitSuite(suite, devFraction: 0.5, seed: 3)
        XCTAssertEqual(dev.decisions.count + test.decisions.count, 3)
        XCTAssertEqual(Set(dev.handIds).intersection(test.handIds), [])
        XCTAssertEqual(dev.handIds.count, 1)
        XCTAssertTrue(dev.id.hasSuffix("-dev") && test.id.hasSuffix("-test"))
    }

    func testTreeBySPR() {
        XCTAssertNil(HandsTreeConfig.forSPR(17.7).addAllin)
        XCTAssertEqual(HandsTreeConfig.forSPR(6).addAllin, true)
        XCTAssertEqual(HandsTreeConfig.forSPR(2).flopBetIP, "33, 75")
        XCTAssertEqual(SuiteParameters.hands(10, format: .mtt20).scenarios.map(\.format), [.mtt20, .mtt20])
        XCTAssertEqual(SuiteParameters.hands(10).scenarios.map(\.id), Scenarios.all.map(\.id))
    }

    /// End-to-end hands generation on a tiny flop game (narrow ranges keep the tree small).
    func testGenerateHandsTiny() async throws {
        let tiny = Scenario(id: "btn-bb-srp", name: "tiny", oopName: "BB", ipName: "BTN", rangeOOP: "QQ,JJ,AQs", rangeIP: "AA,KK,AKs,76s",
                            pot: 5.5, stack: 97.5, summary: "BTN opens 2.5bb, BB calls.")
        let p = SuiteParameters.hands(4, handsPerSolve: 2, seed: 9, targetExploitability: 1, maxIterations: 60)
        let suite = try await SuiteGenerator.generateHands(p, scenariosOverride: [tiny])
        XCTAssertEqual(suite.solves, 2)
        XCTAssertEqual(suite.handIds.count, 4)
        XCTAssertEqual(suite.solveRecords?.count, 2)
        XCTAssertTrue(suite.id.contains("hands4-cash"))
        for h in suite.handIds {
            let ds = suite.decisions.filter { $0.handId == h }
            XCTAssertEqual(ds.map { $0.handSeq! }, Array(0..<ds.count))
            XCTAssertEqual(ds.first?.street, .flop)
            XCTAssertEqual(ds.first?.heroSeat, 0, "OOP acts first")
            XCTAssertEqual(Set(ds.map(\.villainCards)).count, 2, "both seats are recorded with the same two hands")
            for (a, b) in zip(ds, ds.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b.history.count, a.history.count + 1)
                XCTAssertLessThanOrEqual(a.street, b.street)
                XCTAssertTrue(b.board.starts(with: a.board))
            }
            for d in ds {
                XCTAssertEqual(d.actions.count, d.strategy.count)
                XCTAssertEqual(d.board.count, d.street.boardCount)
                XCTAssertTrue(Set(d.heroCardList).isDisjoint(with: d.boardCards))
            }
        }
    }

    // MARK: - Preflop suites

    func testGeneratePreflopPushFold() async throws {
        let p = SuiteParameters.preflop(40, format: .mtt20, seed: 4)
        let suite = try await SuiteGenerator.generatePreflop(p, configOverride: .pushFold(stack: 10))
        XCTAssertEqual(suite.mode, .preflop)
        XCTAssertTrue(suite.isHands)
        XCTAssertEqual(suite.handIds.count, 40)
        XCTAssertTrue(suite.id.contains("preflop40-mtt20"))
        XCTAssertEqual(suite.solveRecords?.count, 1)
        for h in suite.handIds {
            let ds = suite.decisions.filter { $0.handId == h }
            XCTAssertEqual(ds.first?.heroSeat, 0, "the SB acts first preflop")
            XCTAssertLessThanOrEqual(ds.count, 2, "push/fold: SB decision, maybe BB response")
            if ds.count == 2 {
                XCTAssertEqual(ds[1].heroSeat, 1)
                XCTAssertEqual(ds[1].history.last?.action?.kind, .allin)
                XCTAssertEqual(ds[1].actions.map(\.kind), [.fold, .call])
            }
            for d in ds {
                XCTAssertEqual(d.street, .preflop)
                XCTAssertTrue(d.board.isEmpty)
                XCTAssertEqual(d.formatId, "mtt20")
                XCTAssertEqual(d.ante, 1)
                XCTAssertEqual(d.positions, ["SB", "BB"])
                XCTAssertEqual(d.actions.count, d.actionEVs.count)
                XCTAssertEqual(d.strategy.reduce(0, +), 1, accuracy: 0.01)
            }
        }
        let sb = suite.decisions.first { $0.heroSeat == 0 }!
        XCTAssertEqual(sb.actions.map(\.label), ["Fold", "All-in 10"])
        XCTAssertTrue(sb.heroIsIP, "the SB is the button: in position postflop")

        // Every variant builds a preflop request without a board; keys are the usual ones.
        for v in DecisionVariants.all {
            let text = v.requestBody(sb).prettyText
            XCTAssertFalse(text.contains(sb.villainCards), "\(v.id) leaks villain cards")
            XCTAssertTrue(text.contains("allin"), v.id)
        }
        let st = DecisionVariants.eq.requestBody(sb).prettyText
        XCTAssertTrue(st.contains("acts first preflop"))
        XCTAssertTrue(st.contains("1 bb big-blind ante"))
        XCTAssertTrue(st.contains("equity_vs_random_hand_pct"))
        XCTAssertFalse(st.contains("made_hand"))

        // Baselines and per-hand metrics work on preflop suites; seats are named SB / BB.
        let runs = try await BenchmarkRunner.run(suite: suite, players: [Baseline.bestEV, Baseline.random], persist: false)
        let rows = Scoring.leaderboard(suite: suite, runs: runs)
        XCTAssertEqual(rows.first { $0.model == Baseline.bestEV.id }!.perHand!.bbPer100, 0, accuracy: 1e-9)
        XCTAssertNotNil(rows.first { $0.model == Baseline.random.id }!.perHand!.bySeat["SB"])
        XCTAssertNotNil(rows.first?.byStreet["preflop"])
    }

    func testPreflopHeuristics() {
        // AA is the strongest class, 72o among the weakest.
        let aa = Combo(Card("As")!, Card("Ah")!).index, sevenTwo = Combo(Card("7s")!, Card("2h")!).index
        XCTAssertGreaterThan(EquityTools.preflopStrength[aa], 0.84)
        XCTAssertLessThan(EquityTools.preflopStrength[sevenTwo], 0.36)
        XCTAssertEqual(DecisionStateBuilder.handClassCode([Card("7s")!, Card("2h")!]), "72o")
        XCTAssertEqual(DecisionStateBuilder.handClassText([Card("Ks")!, Card("As")!]), "ace-king suited")
        let h = HistoryEntry(street: .preflop, seat: 0, action: SpotAction(kind: .call, amount: 0.5, to: 1, potFraction: 0, name: "Limp (call 0.5)"), potBefore: 1.5)
        XCTAssertEqual(h.text(names: ["SB", "BB"]), "SB limps (calls 0.5 bb)")
        XCTAssertEqual(Street(boardCount: 0), .preflop)
        XCTAssertEqual(Street.flop.boardCount, 3)
        XCTAssertEqual(Street.historyStreets(upTo: .turn), [.flop, .turn])
    }
}
