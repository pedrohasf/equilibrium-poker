import Foundation
import SolverKit

/// One column of the cross-format table: a game format, preflop or postflop suites.
public struct FormatColumn: Hashable, Sendable, Comparable {
    public var format: GameFormat
    public var preflop: Bool

    public init(format: GameFormat, preflop: Bool) {
        self.format = format
        self.preflop = preflop
    }

    public init(_ suite: BenchmarkSuite) { self.init(format: suite.format, preflop: suite.mode == .preflop) }

    /// "cash-post", "spin-pre".
    public var key: String { "\(format.rawValue)-\(preflop ? "pre" : "post")" }
    /// "Cash 100bb post".
    public var title: String { format.shortTitle + (preflop ? " pre" : " post") }

    public static func < (a: FormatColumn, b: FormatColumn) -> Bool {
        let ia = GameFormat.allCases.firstIndex(of: a.format) ?? 0, ib = GameFormat.allCases.firstIndex(of: b.format) ?? 0
        return ia != ib ? ia < ib : (a.preflop && !b.preflop)
    }
}

/// Per-hand bb/100 pooled over every hands/preflop suite of a format.
public struct PooledCell: Sendable {
    /// Hands (sampling units).
    public var n: Int
    public var bbPer100: Double
    public var bbPer100CI: Double
    /// Mixed-strategy bb/100 when every pooled hand has distribution metrics.
    public var mixedBbPer100: Double?
    public var mixedBbPer100CI: Double?
    /// Suite ids that contributed hands.
    public var suiteIds: [String]
}

/// Pools per-hand losses of each player (run label) across the suites of a format. Split suites
/// (`<id>-dev` / `<id>-test`) share hand ids with their parent, so hands are de-duplicated by
/// (root suite, hand id): a player answering the same hand in the parent and a split counts it once.
public enum FormatPool {
    /// `<root>-dev` → (root, "dev"); other ids → (id, nil).
    public static func split(_ suiteId: String) -> (root: String, split: String?) {
        for tag in ["dev", "test"] where suiteId.hasSuffix("-\(tag)") {
            return (String(suiteId.dropLast(tag.count + 1)), tag)
        }
        return (suiteId, nil)
    }

    public struct Result: Sendable {
        /// Columns with their suite ids, in display order.
        public var columns: [(column: FormatColumn, suiteIds: [String])]
        /// label → column → pooled cell.
        public var cells: [String: [FormatColumn: PooledCell]]
        /// A representative run per label (kind, model, variant, derived info).
        public var runs: [String: BenchmarkRun]
    }

    public static func pool(suites: [BenchmarkSuite], runs: [BenchmarkRun]) -> Result {
        let hs = suites.filter(\.isHands).sorted { $0.id < $1.id }
        var cols: [FormatColumn: [String]] = [:]
        // label → column → handKey → (loss, mixed)
        var acc: [String: [FormatColumn: [String: (loss: Double, mixed: Double?)]]] = [:]
        var contributed: [String: [FormatColumn: Set<String>]] = [:]
        var reps: [String: BenchmarkRun] = [:]
        let bySuite = Dictionary(grouping: runs.filter { !$0.results.isEmpty }, by: \.suiteId)
        for s in hs {
            let col = FormatColumn(s)
            cols[col, default: []].append(s.id)
            let root = split(s.id).root
            for r in (bySuite[s.id] ?? []).sorted(by: { $0.id < $1.id }) {
                let hands = Scoring.handLosses(Scoring.scores(r, suite: s), suite: s)
                guard !hands.isEmpty else { continue }
                reps[r.label] = reps[r.label] ?? r
                for (h, v) in hands {
                    let key = "\(root)/\(h)"
                    if acc[r.label]?[col]?[key] != nil { continue }
                    acc[r.label, default: [:]][col, default: [:]][key] = (v.loss, v.mixed)
                    contributed[r.label, default: [:]][col, default: []].insert(s.id)
                }
            }
        }
        var cells: [String: [FormatColumn: PooledCell]] = [:]
        for (label, byCol) in acc {
            for (col, hands) in byCol {
                let keys = hands.keys.sorted()
                let x = Scoring.meanCI(keys.map { 100 * hands[$0]!.loss / 2 })
                let mixed = keys.compactMap { hands[$0]!.mixed }
                let mx = mixed.count == keys.count ? Scoring.meanCI(mixed.map { 100 * $0 / 2 }) : nil
                cells[label, default: [:]][col] = PooledCell(n: keys.count, bbPer100: x.mean, bbPer100CI: x.ci,
                                                             mixedBbPer100: mx?.mean, mixedBbPer100CI: mx?.ci,
                                                             suiteIds: (contributed[label]?[col] ?? []).sorted())
            }
        }
        return Result(columns: cols.keys.sorted().map { ($0, cols[$0]!) }, cells: cells, runs: reps)
    }
}
