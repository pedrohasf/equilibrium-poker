import Foundation
import SolverKit

/// Aggregated statistics for one of the 169 hand classes at a node.
struct ClassStats {
    let handClass: HandClass
    /// Sum of reach over the class's combos present at the node.
    var reach: Float = 0
    /// Number of combos present (non-zero reach, no board conflict).
    var combos: Int = 0
    /// Reach-weighted action frequencies (acting player only).
    var frequencies: [Float] = []
    /// Reach-weighted EV (bb) and equity.
    var ev: Float = 0
    var equity: Float = 0
    /// Reach-weighted EV per action.
    var actionEVs: [Float] = []
    /// Indices into the node's `players[p].hands`.
    var hands: [Int] = []

    /// Fraction of the class still in range: reach / total combos of the class (0...1).
    var fraction: Float { min(1, reach / Float(handClass.comboCount)) }
    var isEmpty: Bool { reach <= 0 }
}

/// Per-class aggregation of a node for one player — the data behind the strategy matrix.
struct MatrixData {
    let player: Int
    let isActing: Bool
    let actions: [ActionInfo]
    /// 169 cells, row-major in `HandClass.grid` order.
    let cells: [ClassStats]
    let totalReach: Float
    let rangeEV: Float
    let rangeEquity: Float
    let minEV: Float
    let maxEV: Float
    let pot: Float
    /// Range-level action frequencies (acting player only).
    let frequencies: [Float]
    /// Range-level EV of each action (reach-weighted over the whole range).
    let actionEVs: [Float]

    static func cellIndex(_ cls: HandClass) -> Int {
        let p = cls.gridPosition
        return p.row * 13 + p.col
    }

    /// Lookup from solver combo index to grid cell, built once.
    private static let comboCell: [Int] = Combo.all.map { cellIndex($0.handClass) }

    func stats(_ cls: HandClass) -> ClassStats { cells[Self.cellIndex(cls)] }

    init(node: NodeInfo, player p: Int) {
        player = p
        isActing = node.player == p && node.kind == .action
        actions = isActing ? node.actions : []
        pot = node.pot
        let na = actions.count
        var cells = (0..<169).map { i in ClassStats(handClass: HandClass.at(row: i / 13, col: i % 13)) }
        for i in cells.indices {
            cells[i].frequencies = Array(repeating: 0, count: na)
            cells[i].actionEVs = Array(repeating: 0, count: na)
        }
        var total: Float = 0, evSum: Float = 0, eqSum: Float = 0
        var freq = [Float](repeating: 0, count: na)
        var aev = [Float](repeating: 0, count: na)
        let hands = p < node.players.count ? node.players[p].hands : []
        for (hi, h) in hands.enumerated() {
            guard h.reach > 0, let ci = Combo.index(of: h.combo) else { continue }
            let c = Self.comboCell[ci]
            let r = h.reach
            cells[c].reach += r
            cells[c].combos += 1
            cells[c].ev += r * h.ev
            cells[c].equity += r * h.equity
            cells[c].hands.append(hi)
            if na > 0 {
                for a in 0..<min(na, h.strategy.count) {
                    cells[c].frequencies[a] += r * h.strategy[a]
                    freq[a] += r * h.strategy[a]
                }
                for a in 0..<min(na, h.actionEvs.count) {
                    cells[c].actionEVs[a] += r * h.actionEvs[a]
                    aev[a] += r * h.actionEvs[a]
                }
            }
            total += r
            evSum += r * h.ev
            eqSum += r * h.equity
        }
        var lo = Float.infinity, hi = -Float.infinity
        for i in cells.indices where cells[i].reach > 0 {
            let r = cells[i].reach
            cells[i].ev /= r
            cells[i].equity /= r
            for a in 0..<na {
                cells[i].frequencies[a] /= r
                cells[i].actionEVs[a] /= r
            }
            lo = min(lo, cells[i].ev)
            hi = max(hi, cells[i].ev)
        }
        self.cells = cells
        totalReach = total
        rangeEV = total > 0 ? evSum / total : 0
        rangeEquity = total > 0 ? eqSum / total : 0
        minEV = lo.isFinite ? lo : 0
        maxEV = hi.isFinite ? hi : 0
        frequencies = total > 0 ? freq.map { $0 / total } : freq
        actionEVs = total > 0 ? aev.map { $0 / total } : aev
    }

    /// EV mapped to [-1, 1] around the range average (for the diverging heatmap).
    func evScore(_ ev: Float) -> Double {
        let spread = max(abs(maxEV - rangeEV), abs(rangeEV - minEV), 0.01)
        return Double((ev - rangeEV) / spread)
    }
}
