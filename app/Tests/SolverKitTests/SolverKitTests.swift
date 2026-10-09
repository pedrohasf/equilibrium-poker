import SolverKit
import XCTest

final class SolverKitTests: XCTestCase {
    func testComboIndexMatchesCore() throws {
        let w = try GTOCore.parseRange("AsKs")
        let idx = Combo("AsKs")!.index
        XCTAssertEqual(w[idx], 1)
        XCTAssertEqual(w.reduce(0, +), 1)
    }

    func testRangeRoundTrip() throws {
        let r = try HandRange(parsing: RangeLibrary.bbCallVsBtn)
        let r2 = try HandRange(parsing: r.text)
        XCTAssertEqual(r.weights, r2.weights)
    }

    func testRiverSolveAndQuery() throws {
        let cfg = SolverConfig(board: "2c 3d 7h 8s Kc", rangeOOP: "QQ", rangeIP: "KK,54s", startingPot: 10, effectiveStack: 10,
                               betSizes: BetSizes(river: .init(oop: .init(), ip: .init(bet: "100"))), addAllin: false)
        let s = try GTOSolver(config: cfg)
        let p = try s.solve(maxIterations: 2000, targetExploitability: 0.01)
        XCTAssertLessThan(p.exploitability, 0.05)
        let root = try s.query()
        XCTAssertEqual(root.kind, .action)
        XCTAssertEqual(root.rangeEV(0), 10 * 2.5 / 7, accuracy: 0.02)
        let bet = try s.query([.action(0), .action(1)])
        XCTAssertEqual(bet.player, 0)
        XCTAssertEqual(bet.actionFrequencies[1], 0.5, accuracy: 0.03) // call 50%
    }

    func testEvaluateAndEquity() throws {
        let v = try GTOCore.evaluate([Card.parseList("AsKsQsJsTs2c3d")!, Card.parseList("2c2d7h8s9cJdKh")!])
        XCTAssertEqual(v[0].category, "Straight flush")
        XCTAssertGreaterThan(v[0], v[1])
        let eq = try GTOCore.equity(hand: Card.parseList("AsAh")!, board: [], range: "KK", samples: 20000)
        XCTAssertEqual(eq, 0.82, accuracy: 0.02)
    }
}
