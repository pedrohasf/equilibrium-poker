@testable import BenchKit
import SolverKit
import XCTest

/// `Findings`: calibration buckets and cross-model agreement exported into bench.json.
final class FindingsExportTests: XCTestCase {
    /// EVs: fold 0, call 1, raise A 3 (best), raise B 2.9 (wrong size, 1% pot worse) — pot 10.
    func decision(_ id: String) -> BenchKit.Decision {
        let actions = [SpotAction(kind: .fold, amount: 0, to: 0, potFraction: 0), SpotAction(kind: .call, amount: 5, to: 5, potFraction: 0),
                       SpotAction(kind: .raise, amount: 15, to: 15, potFraction: 0.67), SpotAction(kind: .raise, amount: 25, to: 25, potFraction: 1.2)]
        return BenchKit.Decision(id: id, scenarioId: "btn-bb-srp", scenarioName: "BTN vs BB", preflopSummary: "", positions: ["BB", "BTN"], heroSeat: 0,
                                 street: .river, board: ["Qs", "Jh", "2h", "8d", "3c"], rootStreet: .river, heroCards: "AsKd", villainCards: "QhQd",
                                 flopPot: 5.5, subgamePot: 10, pot: 10, stacks: [90, 95], toCall: 5, history: [], actions: actions,
                                 strategy: [0, 0.2, 0.8, 0], actionEVs: [0, 1, 3, 2.9], equity: 0.4, exploitability: 0.3, spotIndex: 0)
    }

    func suite(_ n: Int) -> BenchmarkSuite {
        BenchmarkSuite(id: "s", name: "s", parameters: .hands(n, format: .cash), decisions: (0..<n).map { decision("d\($0)") }, solves: 1, generationSeconds: 0)
    }

    func run(_ model: String, _ answers: [(Int, [Double])]) -> BenchmarkRun {
        var r = BenchmarkRun(suiteId: "s", model: model, displayName: model, kind: .decisionModel)
        r.results = answers.enumerated().map { i, a in DecisionResult(decisionId: "d\(i)", choice: a.0, actionProbabilities: a.1) }
        return r
    }

    func testBinIndexIsLowerInclusive() {
        let e = Findings.coarseEdges
        XCTAssertEqual(Findings.binIndex(0.39, edges: e), 0)
        XCTAssertEqual(Findings.binIndex(0.4, edges: e), 1)
        XCTAssertEqual(Findings.binIndex(0.8 - 1e-12, edges: e), 3, "normalisation noise at the edge goes up")
        XCTAssertEqual(Findings.binIndex(1.0, edges: e), 3)
        XCTAssertEqual(Findings.topProbability([2, 6, 2]) ?? 0, 0.6, accuracy: 1e-12)
        XCTAssertNil(Findings.topProbability([0, -1]))
        XCTAssertEqual(Findings.canonicalModel("inception/mercury-decide:free"), "inception/mercury-decide")
        XCTAssertEqual(BenchExport.modelName("inception/mercury-decide:free"), "Inception Mercury Decide (free endpoint)")
    }

    func testCalibrationBuckets() {
        let s = suite(4)
        // Confident & right, confident & wrong (call: 2 bb = 20% pot), torn & right, torn & wrong size (1% pot).
        let r = run("openai/gpt-6-luna-decisions", [(2, [0, 0, 0.9, 0.1]), (1, [0, 0.85, 0.15, 0]), (2, [0, 0, 0.5, 0.5]), (3, [0, 0, 0.45, 0.55])])
        let xs = Findings.samples(suites: [s], runs: [r])
        XCTAssertEqual(xs.count, 4)
        let b = Findings.bins(xs)
        XCTAssertEqual(b.map(\.n), [0, 2, 0, 2])
        XCTAssertEqual(b[3].best, 0.5)
        XCTAssertEqual(b[3].lossPot, 0.1, accuracy: 1e-12)
        XCTAssertEqual(b[1].lossPot, 0.005, accuracy: 1e-12)
        XCTAssertEqual(b[3].share, 0.5)
        XCTAssertEqual(b[3].meanTop, 0.875, accuracy: 1e-12)
        // Answers without probabilities or invalid are skipped.
        var bad = r
        bad.results[0].actionProbabilities = nil
        bad.results[1].choice = nil
        XCTAssertEqual(Findings.samples(suites: [s], runs: [bad]).count, 2)
    }

    func testAgreementLevelsVoteSizingAndEscalation() throws {
        let s = suite(2)
        let p: [Double] = [0, 0, 1, 0]
        let core = Findings.coreModels
        // d0: 4 pick raise A (best), Clef picks call. d1: 2× raise A, 2× raise B, 1× call → tie broken to index 2 (best).
        let runs = [
            run(core[0], [(2, [0, 0, 0.55, 0.45]), (3, [0, 0, 0.45, 0.55])]),  // Luna unsure on d1 and wrong size
            run(core[1], [(2, p), (2, p)]),
            run(core[2] + ":free", [(2, p), (3, p)]),
            run(core[3], [(2, p), (2, p)]),
            run(core[4], [(1, p), (1, p)]),
        ]
        let g = try XCTUnwrap(Findings.agreement(suites: [s], runs: runs, minDecisions: 1).first)
        XCTAssertEqual(g.models.count, 5, "free endpoint merged into Mercury")
        XCTAssertEqual(g.levels.map(\.agree), [4, 2])
        XCTAssertEqual(g.majority.best, 1, "plurality tie → lowest index (raise A)")
        let luna = try XCTUnwrap(g.models_.first { $0.model == core[0] })
        XCTAssertEqual(luna.sizingShare, 1, "Luna's only loss is the wrong raise size")
        XCTAssertEqual(g.models_.first { $0.model == core[4] }?.sizingShare, 0)
        // Escalate when Luna < 0.5: d1 (top 0.55) is not escalated at 0.5 but is at 0.6.
        let e5 = try XCTUnwrap(g.escalation.first { $0.threshold == 0.5 }), e6 = try XCTUnwrap(g.escalation.first { $0.threshold == 0.6 })
        XCTAssertEqual(e5.escalated, 0)
        XCTAssertEqual(e6.escalated, 1)
        XCTAssertEqual(e6.lossPot[core[1]] ?? -1, 0, accuracy: 1e-12, "Jev's picks are both best")
        XCTAssertEqual(g.focusLossPot ?? -1, 0.005, accuracy: 1e-12)
        // JSON block renders.
        let j = Findings.agreementJSON(suites: [s], runs: runs, suiteKeys: [:], spotSuiteId: "s", minDecisions: 1).text()
        XCTAssertTrue(j.contains("\"headline\":0"))
    }
}
