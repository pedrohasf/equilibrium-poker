@testable import BenchKit
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
        var a = BenchmarkRun(suiteId: "t", model: "a/good", displayName: "a/good", kind: .llm, options: nil)
        a.results = [DecisionResult(decisionId: "d001", choice: 2, latency: 2, cost: 0.01),
                     DecisionResult(decisionId: "d002", choice: 1, latency: 4, cost: 0.02)]
        var b = BenchmarkRun(suiteId: "t", model: "b/bad", displayName: "b/bad", kind: .llm, options: nil)
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

    func testResponseParsing() {
        let acts = makeDecision().actions
        XCTAssertEqual(ResponseParser.parse("Calling is fine.\n{\"action\": 2}", actions: acts), 1)
        XCTAssertEqual(ResponseParser.parse("```json\n{\"action\": \"3\"}\n```", actions: acts), 2)
        XCTAssertEqual(ResponseParser.parse("{\"action\": \"Call 5 bb\"}", actions: acts), 1)
        XCTAssertEqual(ResponseParser.parse("{\"action\": \"fold\"}", actions: acts), 0)
        XCTAssertEqual(ResponseParser.parse("{\"action\": \"raise to 15bb\"}", actions: acts), 2)
        XCTAssertEqual(ResponseParser.parse("I think we fold. Action: 1", actions: acts), 0)
        XCTAssertEqual(ResponseParser.parse("Final answer\nCall 5 bb", actions: acts), 1)
        XCTAssertEqual(ResponseParser.parse("Option 1 vs option 3... \"action\": 3 }", actions: acts), 2)
        XCTAssertNil(ResponseParser.parse("{\"action\": 9}", actions: acts))
        XCTAssertNil(ResponseParser.parse("I'm not sure.", actions: acts))
        XCTAssertNil(ResponseParser.parse("{\"action\": 1.5}", actions: acts))
    }

    func testPromptMentionsEverythingNeeded() {
        let d = makeDecision()
        let p = PromptBuilder.user(d)
        XCTAssertTrue(p.contains("Your hand: As Kd"))
        XCTAssertTrue(p.contains("Board: Qs Jh 2h 8d 3c"))
        XCTAssertTrue(p.contains("You are BTN, in position"))
        XCTAssertTrue(p.contains("BB bets 5 bb (100% pot)"))
        XCTAssertTrue(p.contains("1. Fold"))
        XCTAssertTrue(p.contains("2. Call 5 bb"))
        XCTAssertTrue(p.contains("3. Raise to 15 bb (67% pot)"))
        XCTAssertTrue(p.contains("5 bb to call"))
        XCTAssertFalse(p.contains("QhQd"), "villain's cards must never leak")
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

    /// A scripted "LLM" that goes through the real prompt + parser path.
    struct ScriptedLLM: DecisionMaker {
        let reply: @Sendable (Decision) -> String
        var id: String { "mock/scripted" }
        var displayName: String { "Scripted" }
        var kind: PlayerKind { .llm }
        func decide(_ d: Decision) async throws -> DecisionResult {
            _ = PromptBuilder.messages(d)
            let text = reply(d)
            let c = ResponseParser.parse(text, actions: d.actions)
            return DecisionResult(decisionId: d.id, choice: c, rawResponse: text, error: c == nil ? "unparseable" : nil,
                                  latency: 1, promptTokens: 500, completionTokens: 100, cost: 0.001)
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
        let llm = ScriptedLLM { d in
            switch d.id {
            case "d001": return "Raise for value.\n{\"action\": 3}"
            case "d002": return "Just call. {\"action\": \"Call 5 bb\"}"
            default: return "hmm"
            }
        }
        let runs = try await BenchmarkRunner.run(suite: suite, players: [llm], concurrency: 2)
        let row = Scoring.summarize(runs[0], suite: suite)
        XCTAssertEqual(row.answered, 3)
        XCTAssertEqual(row.overall.invalidRate, 1.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(row.overall.gtoScore, (100 + 100.0 / 3 + 0) / 3, accuracy: 1e-9)
        XCTAssertEqual(row.totalCost, 0.003, accuracy: 1e-12)
        XCTAssertNotNil(BenchStore.loadRun(id: runs[0].id))
    }
}
