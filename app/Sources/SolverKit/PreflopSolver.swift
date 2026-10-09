import CGTOCore
import Foundation

/// Heads-up preflop configuration (player 0 = SB/button, player 1 = BB). Amounts in bb.
public struct PreflopConfig: Codable, Hashable, Sendable {
    /// Effective stack including the posted blind.
    public var stack: Double
    /// Dead money paid by the BB (big-blind ante).
    public var ante: Double
    /// SB open sizes ("raise to"). Empty with `allowLimp = false` → push/fold.
    public var openSizes: [Double]
    public var allowLimp: Bool
    /// BB raise-to sizes after a limp.
    public var isoSizes: [Double]
    /// 3-bet sizes as multiples of the facing raise-to.
    public var threebet: [Double]
    /// 4-bet+ sizes as multiples of the facing raise-to.
    public var fourbet: [Double]
    public var allin: Bool
    public var maxRaises: Int
    /// Equity realisation at deep SPR for the out-of-position BB / in-position SB.
    public var eqrOOP: Double
    public var eqrIP: Double

    public init(stack: Double, ante: Double = 0, openSizes: [Double] = [2.5], allowLimp: Bool = true, isoSizes: [Double] = [3.5],
                threebet: [Double] = [3.5], fourbet: [Double] = [2.3], allin: Bool = true, maxRaises: Int = 4,
                eqrOOP: Double = 0.88, eqrIP: Double = 1.05) {
        self.stack = stack
        self.ante = ante
        self.openSizes = openSizes
        self.allowLimp = allowLimp
        self.isoSizes = isoSizes
        self.threebet = threebet
        self.fourbet = fourbet
        self.allin = allin
        self.maxRaises = maxRaises
        self.eqrOOP = eqrOOP
        self.eqrIP = eqrIP
    }

    /// Exact push/fold game (SB jams or folds, BB calls or folds).
    public static func pushFold(stack: Double, ante: Double = 0) -> PreflopConfig {
        PreflopConfig(stack: stack, ante: ante, openSizes: [], allowLimp: false, isoSizes: [], threebet: [], fourbet: [], maxRaises: 1)
    }

    /// Sensible tree for a stack depth: push/fold ≤ 12bb, min-raise trees ≤ 30bb, 2.5x deeper.
    public static func standard(stack: Double, ante: Double = 0) -> PreflopConfig {
        if stack <= 12 { return .pushFold(stack: stack, ante: ante) }
        if stack <= 30 { return PreflopConfig(stack: stack, ante: ante, openSizes: [2], isoSizes: [3], threebet: [3], fourbet: [2.2]) }
        return PreflopConfig(stack: stack, ante: ante)
    }

    enum CodingKeys: String, CodingKey {
        case stack, ante, allin, threebet, fourbet
        case openSizes = "open_sizes"
        case allowLimp = "allow_limp"
        case isoSizes = "iso_sizes"
        case maxRaises = "max_raises"
        case eqrOOP = "eqr_oop"
        case eqrIP = "eqr_ip"
    }
}

/// Heads-up preflop solver backed by the Rust core. Queries return `NodeInfo` with
/// `street == "preflop"`, an empty board, players [SB, BB], and node-relative EVs.
/// Exploitability is reported in milli-big-blinds per hand.
public final class PreflopSolver: @unchecked Sendable {
    private let handle: OpaquePointer
    public let config: PreflopConfig

    public init(config: PreflopConfig) throws {
        self.config = config
        var err: UnsafeMutablePointer<CChar>?
        guard let h = gto_preflop_create(try Bridge.json(config), &err) else {
            _ = try Bridge.take(err)
            throw SolverError("could not create preflop solver")
        }
        handle = h
    }

    deinit { gto_preflop_free(handle) }

    @discardableResult
    public func solve(maxIterations: Int = 3000, targetMBB: Float = 2, checkEvery: Int = 100) throws -> SolveProgress {
        let obj = try Bridge.take(gto_preflop_solve(handle, UInt32(maxIterations), targetMBB, UInt32(max(1, checkEvery)), nil, nil))
        return try Bridge.decode(SolveProgress.self, from: obj["progress"])
    }

    public func stop() { gto_preflop_stop(handle) }

    public func query(_ path: [Int] = []) throws -> NodeInfo {
        let data = try JSONSerialization.data(withJSONObject: path)
        let obj = try Bridge.take(gto_preflop_query(handle, String(decoding: data, as: UTF8.self)))
        return try Bridge.decode(NodeInfo.self, from: obj["node"])
    }
}
