import Foundation
import SolverKit

/// Cross-run findings for the website (`bench.json` → `calibration`, `agreement`): pure functions over stored
/// suites and runs, no API calls.
///
/// * **Calibration** — every decision-model answer with action probabilities, bucketed by the model's top
///   probability ("confidence"): share of answers, best-action rate (pick within `Scoring.bestTolerance` of the pot
///   of the top EV) and mean EV loss % pot with a 95% CI. Buckets are lower-inclusive (`[0.6, 0.8)`), the last one
///   includes 1. All stored answers count (every suite, split and variant).
/// * **Agreement** — per (suite, variant), decisions answered by ≥ 3 of the core models: plurality pick (ties → the
///   lowest action index), its best-action rate and loss by agreement level, the majority-vote player vs each model,
///   the share of each model's loss that is bet sizing, and an escalation simulation for the focus model.
public enum Findings {
    /// The five models compared across suites (`:free` endpoints count as the same model).
    public static let coreModels = ["openai/gpt-6-luna-decisions", "typesafe/jev-1.13", "inception/mercury-decide", "liquid/d1", "cloudflare/clef"]
    public static let shortNames: [String: String] = [
        "openai/gpt-6-luna-decisions": "Luna", "typesafe/jev-1.13": "Jev", "inception/mercury-decide": "Mercury", "liquid/d1": "d1",
        "cloudflare/clef": "Clef", "cloudflare/clef-flash": "Clef Flash", "upstage/solar-decide": "Solar", "upstage/solar-decide-flash": "Solar Flash",
        "perplexity/pplx-decider-v1.1-27b": "Perplexity", "togethercomputer/tev1-4b-experimental": "Tev1", "jaredpalmer/kev-4b": "Kev",
    ]
    /// Coarse confidence buckets (simple view) and fine bins (reliability diagram).
    public static let coarseEdges: [Double] = [0, 0.4, 0.6, 0.8, 1]
    public static let fineEdges: [Double] = [0, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1]
    public static let escalationThresholds: [Double] = [0.5, 0.55, 0.6, 0.65, 0.7, 0.8]

    /// "inception/mercury-decide:free" → "inception/mercury-decide".
    public static func canonicalModel(_ m: String) -> String { m.hasSuffix(":free") ? String(m.dropLast(5)) : m }

    public static func shortName(_ m: String) -> String {
        let c = canonicalModel(m)
        return shortNames[c] ?? String(c.split(separator: "/").last ?? Substring(c))
    }

    // MARK: Calibration

    public struct Sample: Hashable, Sendable {
        public var model: String
        public var variant: String
        public var top: Double
        public var best: Bool
        public var lossPot: Double
    }

    /// Largest normalised probability; nil when the vector has no positive mass.
    public static func topProbability(_ p: [Double]) -> Double? { Scoring.normalized(p)?.max() }

    /// One sample per valid decision-model answer with a probability vector over the decision's actions.
    public static func samples(suites: [BenchmarkSuite], runs: [BenchmarkRun]) -> [Sample] {
        let byId = Dictionary(suites.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Sample] = []
        for run in runs where run.kind == .decisionModel {
            guard let suite = byId[run.suiteId] else { continue }
            let decisions = Dictionary(suite.decisions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for r in run.results {
                guard let d = decisions[r.decisionId], let c = r.choice, d.actions.indices.contains(c),
                      let p = r.actionProbabilities, p.count == d.actions.count, let top = topProbability(p) else { continue }
                let s = Scoring.score(d, choice: c)
                out.append(Sample(model: canonicalModel(run.model), variant: run.variantId ?? DecisionVariants.defaultId,
                                  top: top, best: s.isBest, lossPot: s.evLossPot))
            }
        }
        return out
    }

    public struct Bin: Hashable, Sendable {
        public var lo: Double
        public var hi: Double
        public var n: Int
        /// n / all samples.
        public var share: Double
        public var meanTop: Double
        public var best: Double
        /// 95% CI half-width of `best` (normal approximation).
        public var bestCI: Double
        public var lossPot: Double
        public var lossPotCI: Double
    }

    /// Index of the bucket for `x`: lower-inclusive, the last bucket includes its upper edge (tiny tolerance for
    /// probabilities like 0.8 that normalise to 0.79999…).
    static func binIndex(_ x: Double, edges: [Double]) -> Int {
        let last = edges.count - 2
        for i in 0..<last where x + 1e-9 < edges[i + 1] { return i }
        return last
    }

    public static func bins(_ xs: [Sample], edges: [Double] = coarseEdges) -> [Bin] {
        var groups = Array(repeating: [Sample](), count: edges.count - 1)
        for s in xs { groups[binIndex(s.top, edges: edges)].append(s) }
        let total = Double(max(xs.count, 1))
        return groups.enumerated().map { i, g in
            let n = Double(g.count)
            let best = g.isEmpty ? 0 : Double(g.filter(\.best).count) / n
            let loss = Scoring.meanCI(g.map(\.lossPot))
            return Bin(lo: edges[i], hi: edges[i + 1], n: g.count, share: Double(g.count) / total,
                       meanTop: g.isEmpty ? 0 : g.reduce(0) { $0 + $1.top } / n, best: best,
                       bestCI: g.count > 1 ? 1.96 * (best * (1 - best) / n).squareRoot() : 0, lossPot: loss.mean, lossPotCI: loss.ci)
        }
    }

    public struct Calibration: Sendable {
        public var model: String?
        public var variant: String?
        public var n: Int
        public var meanTop: Double
        public var best: Double
        public var lossPot: Double
        /// Expected calibration error over the fine bins: Σ n_i/n · |mean top_i − best_i|.
        public var ece: Double
        public var buckets: [Bin]
        public var curve: [Bin]
    }

    public static func calibration(_ xs: [Sample], model: String? = nil, variant: String? = nil) -> Calibration {
        let n = Double(max(xs.count, 1))
        let curve = bins(xs, edges: fineEdges)
        return Calibration(model: model, variant: variant, n: xs.count, meanTop: xs.reduce(0) { $0 + $1.top } / n,
                           best: Double(xs.filter(\.best).count) / n, lossPot: xs.reduce(0) { $0 + $1.lossPot } / n,
                           ece: curve.reduce(0) { $0 + Double($1.n) / n * abs($1.meanTop - $1.best) },
                           buckets: bins(xs, edges: coarseEdges), curve: curve)
    }

    // MARK: Agreement

    public struct Stat: Sendable {
        public var n: Int
        public var best: Double
        public var lossPot: Double
        public var lossPotCI: Double
        init(_ xs: [(best: Bool, loss: Double)]) {
            n = xs.count
            best = xs.isEmpty ? 0 : Double(xs.filter(\.best).count) / Double(xs.count)
            let m = Scoring.meanCI(xs.map(\.loss))
            lossPot = m.mean
            lossPotCI = m.ci
        }
    }

    public struct Level: Sendable {
        /// Models that made the plurality pick.
        public var agree: Int
        public var of: Int
        public var share: Double
        public var stat: Stat
    }

    public struct ModelRow: Sendable {
        public var model: String
        public var stat: Stat
        /// Share of the model's total EV loss from picking an aggressive action of the wrong size (chosen and
        /// top-EV actions both bet/raise/all-in, different sizes).
        public var sizingShare: Double
        public var agreesWithMajority: Double
    }

    public struct Escalation: Sendable {
        public var threshold: Double
        /// Share of decisions where the focus model's top probability is below `threshold`.
        public var escalated: Double
        /// Helper model → mean loss % pot of the combined player.
        public var lossPot: [String: Double]
    }

    public struct Group: Sendable {
        public var suiteId: String
        public var variant: String
        public var models: [String]
        public var decisions: Int
        public var levels: [Level]
        public var majority: Stat
        public var models_: [ModelRow]
        /// Paired majority − best single model, loss % pot.
        public var majorityVsBest: Scoring.Diff
        public var bestModel: String
        public var focus: String?
        public var focusLossPot: Double?
        public var escalation: [Escalation]
    }

    /// Plurality pick; ties → the lowest action index.
    public static func plurality(_ picks: [Int]) -> (pick: Int, count: Int)? {
        let counts = Dictionary(picks.map { ($0, 1) }, uniquingKeysWith: +)
        guard let top = counts.values.max() else { return nil }
        return (counts.filter { $0.value == top }.keys.min()!, top)
    }

    /// Chosen and top-EV actions both aggressive but different (right action type, wrong size).
    public static func isSizingError(_ d: Decision, choice: Int) -> Bool {
        let b = d.bestAction
        return choice != b && d.actions[choice].kind.isAggressive && d.actions[b].kind.isAggressive
    }

    public static func agreement(suites: [BenchmarkSuite], runs: [BenchmarkRun], models core: [String] = coreModels,
                                 focus: String = BenchExport.defaultFocusModel, minModels: Int = 3, minDecisions: Int = 20) -> [Group] {
        let coreSet = Set(core)
        // (suite, variant) → model → decision → result (first non-free run wins on duplicates).
        var acc: [String: [String: [String: DecisionResult]]] = [:]
        var keyParts: [String: (String, String)] = [:]
        for run in runs.sorted(by: { ($0.model.hasSuffix(":free") ? 1 : 0, $0.id) < ($1.model.hasSuffix(":free") ? 1 : 0, $1.id) })
        where run.kind == .decisionModel && coreSet.contains(canonicalModel(run.model)) {
            let v = run.variantId ?? DecisionVariants.defaultId
            let key = "\(run.suiteId)|\(v)"
            keyParts[key] = (run.suiteId, v)
            let m = canonicalModel(run.model)
            for r in run.results where r.choice != nil && acc[key]?[m]?[r.decisionId] == nil { acc[key, default: [:]][m, default: [:]][r.decisionId] = r }
        }
        let byId = Dictionary(suites.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var groups: [Group] = []
        for key in acc.keys.sorted() {
            guard let (sid, variant) = keyParts[key], let suite = byId[sid], let answers = acc[key] else { continue }
            let maxCount = answers.values.map(\.count).max() ?? 0
            let models = core.filter { (answers[$0]?.count ?? 0) * 2 >= maxCount && (answers[$0]?.count ?? 0) > 0 }
            guard models.count >= minModels else { continue }
            let ds = suite.decisions.filter { d in models.allSatisfy { answers[$0]![d.id].flatMap(\.choice).map { d.actions.indices.contains($0) } == true } }
            guard ds.count >= minDecisions else { continue }
            let k = models.count
            var levelAcc: [Int: [(Bool, Double)]] = [:]
            var vote: [(best: Bool, loss: Double)] = []
            var per: [String: [(best: Bool, loss: Double)]] = [:]
            var sizing: [String: Double] = [:]
            var agreeCount: [String: Int] = [:]
            for d in ds {
                let picks = models.map { answers[$0]![d.id]!.choice! }
                let (p, c) = plurality(picks)!
                let s = Scoring.score(d, choice: p)
                levelAcc[c, default: []].append((s.isBest, s.evLossPot))
                vote.append((s.isBest, s.evLossPot))
                for (m, pick) in zip(models, picks) {
                    let ms = Scoring.score(d, choice: pick)
                    per[m, default: []].append((ms.isBest, ms.evLossPot))
                    if isSizingError(d, choice: pick) { sizing[m, default: 0] += ms.evLossPot }
                    if pick == p { agreeCount[m, default: 0] += 1 }
                }
            }
            let n = Double(ds.count)
            let levels = levelAcc.keys.sorted(by: >).map { c in
                Level(agree: c, of: k, share: Double(levelAcc[c]!.count) / n, stat: Stat(levelAcc[c]!.map { (best: $0.0, loss: $0.1) }))
            }
            let rows = models.map { m -> ModelRow in
                let st = Stat(per[m]!)
                let total = per[m]!.reduce(0) { $0 + $1.loss }
                return ModelRow(model: m, stat: st, sizingShare: total > 0 ? (sizing[m] ?? 0) / total : 0,
                                agreesWithMajority: Double(agreeCount[m] ?? 0) / n)
            }
            let bestRow = rows.min { $0.stat.lossPot < $1.stat.lossPot }!
            let diffs = zip(vote, per[bestRow.model]!).map { $0.loss - $1.loss }
            let dm = Scoring.meanCI(diffs)
            // Escalation: the focus model hands its decision to a helper when its top probability is below t.
            var esc: [Escalation] = []
            if models.contains(focus) {
                let tops = ds.map { d in answers[focus]![d.id]!.actionProbabilities.flatMap(topProbability) ?? 1 }
                for t in escalationThresholds {
                    var loss: [String: Double] = [:]
                    for h in models where h != focus {
                        loss[h] = zip(ds.indices, ds).reduce(0) { acc, x in
                            let (i, d) = x
                            let src = tops[i] + 1e-9 < t ? h : focus
                            return acc + Scoring.score(d, choice: answers[src]![d.id]!.choice!).evLossPot
                        } / n
                    }
                    esc.append(Escalation(threshold: t, escalated: Double(tops.filter { $0 + 1e-9 < t }.count) / n, lossPot: loss))
                }
            }
            groups.append(Group(suiteId: sid, variant: variant, models: models, decisions: ds.count, levels: levels, majority: Stat(vote),
                                models_: rows, majorityVsBest: Scoring.Diff(n: diffs.count, mean: dm.mean, ci: dm.ci), bestModel: bestRow.model,
                                focus: models.contains(focus) ? focus : nil,
                                focusLossPot: models.contains(focus) ? rows.first { $0.model == focus }?.stat.lossPot : nil, escalation: esc))
        }
        return groups
    }

    // MARK: JSON

    static func binObj(_ b: Bin) -> EJ {
        .o([("lo", .n(b.lo, 2)), ("hi", .n(b.hi, 2)), ("n", .i(b.n)), ("share", .n(b.share, 4)), ("meanTop", .n(b.meanTop, 4)),
            ("best", .n(b.best, 4)), ("bestCI", .n(b.bestCI, 4)), ("lossPot", .n(b.lossPot, 5)), ("lossPotCI", .n(b.lossPotCI, 5))])
    }

    static func calObj(_ c: Calibration, catalog: [String: BenchExport.CatalogEntry]) -> EJ {
        var f: [(String, EJ)] = []
        if let m = c.model { f += [("model", .s(m)), ("name", .s(BenchExport.modelName(m, catalog: catalog))), ("short", .s(shortName(m)))] }
        if let v = c.variant { f.append(("variant", .s(v))) }
        f += [("n", .i(c.n)), ("meanTop", .n(c.meanTop, 4)), ("best", .n(c.best, 4)), ("lossPot", .n(c.lossPot, 5)), ("ece", .n(c.ece, 4)),
              ("buckets", .a(c.buckets.map(binObj))), ("curve", .a(c.curve.map(binObj)))]
        return .o(f)
    }

    static func statObj(_ s: Stat) -> [(String, EJ)] {
        [("n", .i(s.n)), ("best", .n(s.best, 4)), ("lossPot", .n(s.lossPot, 5)), ("lossPotCI", .n(s.lossPotCI, 5))]
    }

    /// `calibration` block: overall + per model (+ per model × variant with ≥ `minVariantN` answers).
    public static func calibrationJSON(suites: [BenchmarkSuite], runs: [BenchmarkRun], focus: String = BenchExport.defaultFocusModel,
                                       catalog: [String: BenchExport.CatalogEntry] = [:], minVariantN: Int = 100) -> EJ {
        let xs = samples(suites: suites, runs: runs)
        let byModel = Dictionary(grouping: xs, by: \.model)
        let models = byModel.keys.sorted { (byModel[$0]!.count, $1) > (byModel[$1]!.count, $0) }
        let variants: [EJ] = models.flatMap { m -> [EJ] in
            let g = Dictionary(grouping: byModel[m]!, by: \.variant)
            return g.keys.sorted().filter { g[$0]!.count >= minVariantN }.map { calObj(calibration(g[$0]!, model: m, variant: $0), catalog: catalog) }
        }
        return .o([
            ("definition", .s("Decision-model answers with action probabilities, all stored suites/variants. Confidence = top probability; buckets lower-inclusive. Best = pick within \(Scoring.bestTolerance * 100)% pot of the top EV.")),
            ("focus", .s(focus)), ("edges", .a(coarseEdges.map { .n($0, 2) })), ("fineEdges", .a(fineEdges.map { .n($0, 2) })),
            ("overall", calObj(calibration(xs), catalog: catalog)),
            ("models", .a(models.map { calObj(calibration(byModel[$0]!, model: $0), catalog: catalog) })),
            ("variants", .a(variants)),
        ])
    }

    /// `agreement` block: one entry per (suite, variant) with ≥ 3 core models; `headline` = the spot suite's default variant.
    public static func agreementJSON(suites: [BenchmarkSuite], runs: [BenchmarkRun], suiteKeys: [String: String], spotSuiteId: String?,
                                     focus: String = BenchExport.defaultFocusModel, catalog: [String: BenchExport.CatalogEntry] = [:],
                                     minDecisions: Int = 20) -> EJ {
        let gs = agreement(suites: suites, runs: runs, focus: focus, minDecisions: minDecisions)
        let byId = Dictionary(suites.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func model(_ m: String) -> [(String, EJ)] { [("model", .s(m)), ("name", .s(BenchExport.modelName(m, catalog: catalog))), ("short", .s(shortName(m)))] }
        let objs: [EJ] = gs.map { g in
            let s = byId[g.suiteId]
            return .o([
                ("suite", .s(g.suiteId)), ("key", suiteKeys[g.suiteId].map { .s($0) } ?? .null),
                ("title", .s(s.map { $0.mode == .spots ? "\($0.decisions.count)-spot suite" : "\($0.format.shortTitle) \($0.mode == .preflop ? "preflop" : "hands")" + (FormatPool.split($0.id).split.map { " · \($0)" } ?? "") } ?? g.suiteId)),
                ("variant", .s(g.variant)), ("decisions", .i(g.decisions)),
                ("models", .a(g.models.map { .o(model($0)) })),
                ("levels", .a(g.levels.map { l in .o([("agree", .i(l.agree)), ("of", .i(l.of)), ("share", .n(l.share, 4))] + statObj(l.stat)) })),
                ("majority", .o(statObj(g.majority))),
                ("bestModel", .s(g.bestModel)),
                ("majorityVsBest", .o([("n", .i(g.majorityVsBest.n)), ("mean", .n(g.majorityVsBest.mean, 5)), ("ci", .n(g.majorityVsBest.ci, 5)),
                                       ("sig", .b(g.majorityVsBest.significant))])),
                ("players", .a(g.models_.map { r in .o(model(r.model) + statObj(r.stat) + [("sizingShare", .n(r.sizingShare, 4)),
                                                                                           ("agreesWithMajority", .n(r.agreesWithMajority, 4))]) })),
                ("focus", g.focus.map { .s($0) } ?? .null), ("focusLossPot", .opt(g.focusLossPot, 5)),
                ("escalation", .a(g.escalation.map { e in
                    .o([("threshold", .n(e.threshold, 2)), ("escalated", .n(e.escalated, 4)),
                        ("lossPot", .o(e.lossPot.keys.sorted().map { ($0, EJ.n(e.lossPot[$0]!, 5)) }))])
                })),
            ])
        }
        let headline = gs.firstIndex { $0.suiteId == spotSuiteId && $0.variant == DecisionVariants.defaultId }
            ?? gs.indices.max { gs[$0].decisions * gs[$0].models.count < gs[$1].decisions * gs[$1].models.count }
        return .o([
            ("definition", .s("Per suite and variant, decisions answered by every listed core model (≥ 3 of \(coreModels.map(shortName).joined(separator: ", ")); free endpoints merged). Plurality of the picks, ties → lowest action index. Sizing share = loss where the chosen and top-EV actions are both bet/raise/all-in of different sizes, ÷ total loss.")),
            ("core", .a(coreModels.map { .o(model($0)) })),
            ("headline", headline.map { .i($0) } ?? .null),
            ("groups", .a(objs)),
        ])
    }
}
