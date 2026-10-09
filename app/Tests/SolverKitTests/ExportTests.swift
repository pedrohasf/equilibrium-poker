@testable import ArenaKit
@testable import BenchKit
import SolverKit
import XCTest

/// `bench export --all` (bench.json bundle, per-format pooling) and `arena export`.
final class BenchExportTests: XCTestCase {
    func decision(_ id: String, hand: String, seat: Int) -> BenchKit.Decision {
        let actions = [SpotAction(kind: .fold, amount: 0, to: 0, potFraction: 0), SpotAction(kind: .call, amount: 5, to: 5, potFraction: 0),
                       SpotAction(kind: .raise, amount: 15, to: 15, potFraction: 0.67)]
        var d = BenchKit.Decision(id: id, scenarioId: "btn-bb-srp", scenarioName: "BTN vs BB", preflopSummary: "", positions: ["BB", "BTN"], heroSeat: seat,
                         street: .river, board: ["Qs", "Jh", "2h", "8d", "3c"], rootStreet: .flop, heroCards: "AsKd", villainCards: "QhQd",
                         flopPot: 5.5, subgamePot: 5.5, pot: 10, stacks: [90, 95], toCall: 5, history: [], actions: actions,
                         strategy: [0, 0.3, 0.7], actionEVs: [0, 1, 3], equity: 0.4, exploitability: 0.3, spotIndex: 0)
        d.handId = hand
        return d
    }

    func suite(_ id: String, hands: [String]) -> BenchmarkSuite {
        let ds = hands.enumerated().map { i, h in decision("d\(i)", hand: h, seat: i % 2) }
        return BenchmarkSuite(id: id, name: id, parameters: .hands(hands.count, format: .cash), decisions: ds, solves: 1, generationSeconds: 0)
    }

    func run(_ suiteId: String, _ model: String, kind: PlayerKind = .decisionModel, variant: String? = nil, choice: Int) -> (BenchmarkSuite) -> BenchmarkRun {
        { s in
            var r = BenchmarkRun(suiteId: suiteId, model: model, displayName: model, kind: kind, variant: variant)
            r.results = s.decisions.map { DecisionResult(decisionId: $0.id, choice: choice, actionProbabilities: nil) }
            return r
        }
    }

    func testFormatPoolDedupesSplitHands() {
        let parent = suite("p", hands: ["h1", "h2", "h3", "h4"])
        var dev = parent, test = parent
        dev.id = "p-dev"; dev.decisions = Array(parent.decisions.prefix(2))
        test.id = "p-test"; test.decisions = Array(parent.decisions.suffix(2))
        // Same model on the parent and on dev: dev's hands h1, h2 must be counted once.
        let runs = [run("p", "m/a", choice: 1)(parent), run("p-dev", "m/a", choice: 1)(dev), run("p", "baseline:random", kind: .baseline, choice: 0)(parent)]
        let pooled = FormatPool.pool(suites: [parent, dev, test], runs: runs)
        let col = FormatColumn(format: .cash, preflop: false)
        XCTAssertEqual(pooled.columns.first?.suiteIds, ["p", "p-dev", "p-test"])
        let cell = pooled.cells["m/a [v2]"]![col]!
        XCTAssertEqual(cell.n, 4, "parent + dev share hands; each counted once")
        XCTAssertEqual(cell.bbPer100, 100, accuracy: 1e-9) // call loses 2 bb per hand → 2/2 × 100
        // Same numbers as the CLI table.
        XCTAssertTrue(BenchCLI.formatsText(suites: [parent, dev, test], runs: runs).contains("100.0 ±0.0 [4]"))
        XCTAssertEqual(FormatPool.split("x-dev").root, "x")
        XCTAssertNil(FormatPool.split("x").split)
    }

    func testBundleBorrowsBaselinesAndPairsVariants() throws {
        let parent = suite("20260101-hands120-cash", hands: (1...60).map { "h\($0)" })
        var dev = parent
        dev.id = parent.id + "-dev"
        let focus = BenchExport.defaultFocusModel
        let runs = [run(dev.id, focus, choice: 1)(dev), run(dev.id, focus, variant: "eq", choice: 2)(dev),
                    run(parent.id, "baseline:gto", kind: .baseline, choice: 2)(parent)]
        let b = BenchExport.bundle(suites: [parent, dev], runs: runs)
        let text = b.manifest.text()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let suites = try XCTUnwrap(json["suites"] as? [[String: Any]])
        XCTAssertEqual(suites.map { $0["key"] as? String }, ["cash-hands", "cash-hands-dev"])
        let devPlayers = try XCTUnwrap(suites[1]["players"] as? [[String: Any]])
        XCTAssertTrue(devPlayers.contains { $0["model"] as? String == "baseline:gto" && $0["borrowed"] as? Bool == true })
        XCTAssertEqual(b.suiteDocuments.map(\.key), ["cash-hands-dev"], "decision files only for suites with model runs")
        let exp = try XCTUnwrap((json["experiments"] as? [[String: Any]])?.first)
        let rows = try XCTUnwrap(exp["rows"] as? [[String: Any]])
        let eq = try XCTUnwrap(rows.first { $0["variant"] as? String == "eq" })
        let diff = try XCTUnwrap(((eq["dev"] as? [String: Any])?["diff"] as? [String: Any])?["bb"] as? [String: Any])
        XCTAssertEqual(diff["mean"] as? Double, -100, "raise (0 loss) vs call (2 bb per hand) = −100 bb/100")
        XCTAssertEqual(diff["sig"] as? Bool, true, "identical per-hand differences: CI 0, significant")
    }

    func testPublishedThresholds() {
        XCTAssertFalse(BenchExport.isPublished(suite("tiny", hands: ["h1", "h2"])))
        XCTAssertTrue(BenchExport.isPublished(suite("ok", hands: (1...50).map { "h\($0)" })))
    }

    func testArenaExportPoolsPerOpponent() async throws {
        let m1 = await MatchRunner.run(config: MatchConfig(deals: 60, seed: 1), specs: [.bot(.tag), .bot(.random)],
                                       players: [TightAggressiveBot(), RandomBot()], save: false)
        let m2 = await MatchRunner.run(config: MatchConfig(deals: 60, seed: 2), specs: [.bot(.random), .bot(.tag)],
                                       players: [RandomBot(), TightAggressiveBot()], save: false)
        let small = await MatchRunner.run(config: MatchConfig(deals: 10, seed: 3), specs: [.bot(.tag), .bot(.station)],
                                          players: [TightAggressiveBot(), CallingStation()], save: false)
        let doc = ArenaExport.document(matches: [m1, m2, small])
        XCTAssertEqual(doc["excluded"] as? Int, 1, "< 100 hands")
        let pairs = try XCTUnwrap(doc["pairs"] as? [[String: Any]])
        let tag = try XCTUnwrap(pairs.first { $0["player"] as? String == "bot:tag" && $0["opponent"] as? String == "bot:random" })
        XCTAssertEqual(tag["hands"] as? Int, 240)
        XCTAssertEqual(tag["units"] as? Int, 120)
        let units = MatchStats.units(m1.hands, player: 0, duplicate: true) + MatchStats.units(m2.hands, player: 1, duplicate: true)
        XCTAssertEqual(tag["bb100"] as? Double ?? .nan, (MatchStats.rate(units).bb100 * 100).rounded() / 100, accuracy: 1e-9)
        let rnd = try XCTUnwrap(pairs.first { $0["player"] as? String == "bot:random" })
        XCTAssertEqual(rnd["netBB"] as? Double ?? .nan, -(tag["netBB"] as? Double ?? .nan), accuracy: 0.02)
        // Single-match pairing equals the per-match summary (what `arena show` prints).
        let s1 = MatchStats.summarize(m1).players[0]
        let one = ArenaExport.document(matches: [m1])
        let p1 = try XCTUnwrap((one["pairs"] as? [[String: Any]])?.first { $0["player"] as? String == "bot:tag" })
        XCTAssertEqual(p1["vpip"] as? Double ?? .nan, (s1.vpip! * 1e4).rounded() / 1e4, accuracy: 1e-9)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: doc))
    }
}
