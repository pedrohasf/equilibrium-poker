import Foundation
import OpenRouterKit
import SolverKit

/// `eqbench bench export --all`: everything the website shows, from whatever suites and runs exist.
///
/// Files (under `--out-dir`, default `<repo>/web/data`):
/// * `bench.json` — manifest: the spot suite's leaderboard (no per-decision data), every published hands/preflop
///   suite with its scored players, per-format pooled bb/100 (`FormatPool`, = `bench formats --published`) and the
///   dev/test variant experiments of the focus model (paired differences vs its default variant, = `bench compare`).
/// * `results.json` — the spot suite with every decision (spot explorer; unchanged schema).
/// * `suites/<key>.json` — same schema for each published suite that has decision-model or derived runs.
///
/// All numbers come from `Scoring` (summaries, `handMetrics`, `paired`), so they match the CLI reports.
extension BenchExport {
    public static let bundleSchemaVersion = 1
    /// Suites smaller than this are tests and are not published.
    public static let minHandsDecisions = 50
    public static let minPreflopDecisions = 100
    public static let defaultFocusModel = "openai/gpt-6-luna-decisions"

    public static func isPublished(_ s: BenchmarkSuite) -> Bool {
        switch s.mode {
        case .hands: return s.decisions.count >= minHandsDecisions
        case .preflop: return s.decisions.count >= minPreflopDecisions
        case .spots: return false
        }
    }

    /// The spots suite with the most decision-model runs (then the most decisions, then the newest).
    public static func defaultSpotSuite(_ suites: [BenchmarkSuite], runs: [BenchmarkRun]) -> BenchmarkSuite? {
        let dmCount = Dictionary(grouping: runs.filter { $0.kind == .decisionModel && !$0.results.isEmpty }, by: \.suiteId).mapValues(\.count)
        return suites.filter { $0.mode == .spots }.max { a, b in
            let ka = (dmCount[a.id] ?? 0, a.decisions.count, a.createdAt), kb = (dmCount[b.id] ?? 0, b.decisions.count, b.createdAt)
            return ka < kb
        }
    }

    /// Runs scored on `suite`: its own runs, plus — for a dev/test split — the parent suite's baseline runs that the
    /// split lacks (bots are deterministic per decision, so their answers carry over). Returns the ids of borrowed runs.
    public static func scoredRuns(for suite: BenchmarkSuite, all: [BenchmarkRun]) -> (runs: [BenchmarkRun], borrowed: Set<String>) {
        var own = all.filter { $0.suiteId == suite.id && !$0.results.isEmpty }
        var borrowed = Set<String>()
        let (root, split) = FormatPool.split(suite.id)
        if split != nil {
            let have = Set(own.filter { $0.kind == .baseline }.map(\.model))
            for r in all where r.suiteId == root && r.kind == .baseline && !have.contains(r.model) && !r.results.isEmpty {
                var c = r
                c.suiteId = suite.id
                c.id = BenchmarkRun.makeId(suiteId: suite.id, model: r.model)
                own.append(c)
                borrowed.insert(c.id)
            }
        }
        return (own, borrowed)
    }

    /// Stable short key for a suite file / explorer link: "cash-hands", "cash-hands-dev", "spin-preflop".
    static func suiteKey(_ s: BenchmarkSuite, used: inout Set<String>) -> String {
        let split = FormatPool.split(s.id).split
        let base = s.mode == .spots ? "spots" : "\(s.format.rawValue)-\(s.mode == .preflop ? "preflop" : "hands")" + (split.map { "-\($0)" } ?? "")
        var key = base, n = 2
        while used.contains(key) { key = "\(base)-\(n)"; n += 1 }
        used.insert(key)
        return key
    }

    static func diff(_ d: Scoring.Diff?, _ places: Int = 2) -> EJ {
        guard let d, d.n > 0 else { return .null }
        return .o([("n", .i(d.n)), ("mean", .n(d.mean, places)), ("ci", .n(d.ci, places)), ("sig", .b(d.significant))])
    }

    static func derivedObj(_ run: BenchmarkRun) -> EJ {
        guard let dv = run.derived else { return .null }
        return .o([("method", .s(dv.method)), ("description", .s(dv.description)), ("hybrid", .b(dv.hybrid)),
                   ("sources", .a(dv.sources.map { .s($0) }))])
    }

    /// Identity fields shared by every per-player object in bench.json.
    static func identity(_ run: BenchmarkRun, catalog: [String: CatalogEntry]) -> [(String, EJ)] {
        var f: [(String, EJ)] = [("label", .s(run.label)), ("name", .s(displayName(run, catalog: catalog))), ("kind", .s(run.kind.rawValue)),
                                 ("model", .s(run.model))]
        if run.kind != .derived { f.append(("modelName", .s(modelName(run.model, catalog: catalog)))) }
        if let b = Baseline(id: run.model) { f += [("baseline", .s(b.rawValue)), ("summary", .s(b.summary))] }
        if run.kind == .decisionModel, let v = run.variantId { f.append(("variant", .s(v))) }
        if run.derived != nil { f.append(("derived", derivedObj(run))) }
        return f
    }

    /// Compact scored row (no breakdowns) for bench.json.
    static func summaryRow(key: String, row: ModelScore, run: BenchmarkRun, catalog: [String: CatalogEntry], borrowed: Bool) -> EJ {
        let o = row.overall
        var f: [(String, EJ)] = [("key", .s(key))] + identity(run, catalog: catalog)
        if borrowed { f.append(("borrowed", .b(true))) }
        f += [("answered", .i(row.answered)), ("total", .i(row.total)), ("complete", .b(row.isComplete)),
              ("score", .n(o.gtoScore, 2)), ("scoreCI", .n(o.gtoScoreCI, 2)),
              ("lossPot", .n(o.meanEVLossPot, 5)), ("lossPotCI", .n(o.meanEVLossPotCI, 5)),
              ("mixedPot", .opt(o.meanMixedEVLossPot, 5)), ("best", .n(o.accuracy, 4)), ("blunder", .n(o.blunderRate, 4)),
              ("invalid", .n(o.invalidRate, 4)), ("tv", .opt(o.meanTVDistance, 4)), ("pBest", .opt(o.meanBestActionProbability, 4))]
        if let h = row.perHand {
            f.append(("perHand", .o([("hands", .i(h.hands)), ("bb", .n(h.bbPer100, 2)), ("ci", .n(h.bbPer100CI, 2)),
                                     ("mixed", .opt(h.mixedBbPer100, 2)), ("mixedCI", .opt(h.mixedBbPer100CI, 2)),
                                     ("bySeat", .o(h.bySeat.keys.sorted().map { ($0, EJ.n(h.bySeat[$0]!, 2)) }))])))
        }
        if run.kind != .baseline { f.append(("cost", .n(row.totalCost, 5))) }
        return .o(f)
    }

    static func formatObj(_ f: GameFormat) -> EJ {
        .o([("id", .s(f.rawValue)), ("title", .s(f.title)), ("short", .s(f.shortTitle)), ("summary", .s(f.summary))])
    }

    // MARK: Bundle

    public struct Bundle {
        /// bench.json
        public var manifest: EJ
        /// results.json (spot suite with decisions), if a spot suite exists.
        public var spotDocument: EJ?
        /// suites/<key>.json
        public var suiteDocuments: [(key: String, doc: EJ)]
        /// Human-readable notes for the CLI.
        public var log: [String]
    }

    public static func bundle(suites allSuites: [BenchmarkSuite], runs allRuns: [BenchmarkRun], spotSuiteId: String? = nil,
                              focusModel: String = defaultFocusModel, catalog: [String: CatalogEntry] = [:],
                              generatedAt: Date = Date()) -> Bundle {
        var log: [String] = []
        let runs = allRuns.filter { !$0.results.isEmpty }
        let spot = spotSuiteId.flatMap { id in allSuites.first { $0.id == id } } ?? defaultSpotSuite(allSuites, runs: runs)
        let published = allSuites.filter(isPublished).sorted {
            let (a, b) = (FormatColumn($0), FormatColumn($1))
            return a != b ? a < b : $0.id < $1.id
        }
        var usedKeys: Set<String> = spot != nil ? ["spots"] : []
        var suiteObjs: [EJ] = []
        var docs: [(String, EJ)] = []
        var keyOf: [String: String] = [:]
        var scored: [String: (runs: [BenchmarkRun], borrowed: Set<String>)] = [:]

        // Spot suite: leaderboard without decisions (the explorer lazy-loads results.json).
        var spotDoc: EJ?
        var spotSummary: EJ = .null
        if let s = spot {
            let d = document(suite: s, runs: runs, catalog: catalog, generatedAt: generatedAt)
            spotDoc = d
            if case .o(let kv) = d { spotSummary = .o(kv.filter { $0.0 != "decisions" && $0.0 != "schema" && $0.0 != "generator" } + [("file", .s("results.json"))]) }
            keyOf[s.id] = "spots"
        }

        for s in published {
            let key = suiteKey(s, used: &usedKeys)
            keyOf[s.id] = key
            let sr = scoredRuns(for: s, all: runs)
            scored[s.id] = sr
            let rows = Scoring.leaderboard(suite: s, runs: sr.runs)
            let byId = Dictionary(sr.runs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var pk = Set<String>()
            let players: [EJ] = rows.compactMap { r in
                guard let run = byId[r.id] else { return nil }
                return summaryRow(key: playerKey(run, used: &pk), row: r, run: run, catalog: catalog, borrowed: sr.borrowed.contains(run.id))
            }
            let hasModels = sr.runs.contains { $0.kind != .baseline }
            let file = hasModels ? "suites/\(key).json" : nil
            if hasModels { docs.append((key, document(suite: s, runs: sr.runs, catalog: catalog, generatedAt: generatedAt, borrowed: sr.borrowed))) }
            let (root, split) = FormatPool.split(s.id)
            let exps = s.decisions.map(\.exploitability)
            suiteObjs.append(.o([
                ("key", .s(key)), ("id", .s(s.id)), ("name", .s(s.name)), ("mode", .s(s.mode.rawValue)), ("format", formatObj(s.format)),
                ("column", .s(FormatColumn(s).key)), ("root", .s(root)), ("split", split.map { .s($0) } ?? .null),
                ("createdAt", .s(iso(s.createdAt))), ("decisions", .i(s.decisions.count)), ("hands", .i(s.handIds.count)),
                ("solves", .i(s.solves)), ("seed", .s(String(s.parameters.seed))),
                ("streets", .o(Street.allCases.compactMap { st in s.countByStreet[st].map { (st.rawValue, EJ.i($0)) } })),
                ("meanExplPctPot", .n(exps.isEmpty ? 0 : exps.reduce(0, +) / Double(exps.count), 3)),
                ("file", file.map { .s($0) } ?? .null),
                ("players", .a(players)),
            ]))
            log.append("  \(key): \(s.id) · \(s.decisions.count) decisions · \(s.handIds.count) hands · \(rows.count) players"
                       + (sr.borrowed.isEmpty ? "" : " (\(sr.borrowed.count) baselines from \(root))") + (hasModels ? " → \(file!)" : ""))
        }
        let skipped = allSuites.filter { $0.mode != .spots && !isPublished($0) }
        if !skipped.isEmpty { log.append("  skipped (too small): " + skipped.map(\.id).sorted().joined(separator: ", ")) }

        // Per-format pooled bb/100 (= `bench formats --published`).
        let pooled = FormatPool.pool(suites: published, runs: runs)
        let columns: [EJ] = pooled.columns.map { c in
            .o([("key", .s(c.column.key)), ("format", formatObj(c.column.format)), ("phase", .s(c.column.preflop ? "preflop" : "postflop")),
                ("title", .s(c.column.title)), ("suites", .a(c.suiteIds.compactMap { keyOf[$0] }.map { .s($0) })),
                ("hands", .i(published.filter { c.suiteIds.contains($0.id) && FormatPool.split($0.id).split == nil }.reduce(0) { $0 + $1.handIds.count }))])
        }
        let formatRows: [EJ] = pooled.cells.keys.sorted().compactMap { label in
            guard let run = pooled.runs[label], let cells = pooled.cells[label] else { return nil }
            let cs: [(String, EJ)] = cells.keys.sorted().map { col in
                let c = cells[col]!
                return (col.key, .o([("n", .i(c.n)), ("bb", .n(c.bbPer100, 2)), ("ci", .n(c.bbPer100CI, 2)),
                                     ("mixed", .opt(c.mixedBbPer100, 2)), ("mixedCI", .opt(c.mixedBbPer100CI, 2)),
                                     ("suites", .a(c.suiteIds.compactMap { keyOf[$0] }.map { .s($0) }))]))
            }
            return .o(identity(run, catalog: catalog) + [("cells", .o(cs))])
        }

        // Dev/test experiments of the focus model.
        var experiments: [EJ] = []
        let roots = Dictionary(grouping: published.filter { FormatPool.split($0.id).split != nil }, by: { FormatPool.split($0.id).root })
        for root in roots.keys.sorted() {
            let splits = roots[root]!.sorted { $0.id < $1.id }
            guard splits.contains(where: { s in scored[s.id]!.runs.contains { $0.model == focusModel } }) else { continue }
            struct Cell { var split: String; var obj: EJ; var bb: Double?; var diff: Scoring.Diff? }
            var cellsByLabel: [String: [Cell]] = [:]
            var reps: [String: BenchmarkRun] = [:]
            var order: [String] = []
            var meta: [EJ] = []
            for s in splits {
                let split = FormatPool.split(s.id).split!
                let sr = scored[s.id]!
                let ref = sr.runs.first { $0.model == focusModel && $0.kind == .decisionModel && $0.variantId == DecisionVariants.defaultId }
                meta.append(.o([("split", .s(split)), ("suite", .s(keyOf[s.id] ?? s.id)), ("id", .s(s.id)), ("hands", .i(s.handIds.count)),
                                ("decisions", .i(s.decisions.count)), ("reference", ref.map { .s($0.label) } ?? .null)]))
                for r in Scoring.leaderboard(suite: s, runs: sr.runs) {
                    guard let run = sr.runs.first(where: { $0.id == r.id }) else { continue }
                    if reps[run.label] == nil { reps[run.label] = run; order.append(run.label) }
                    let p = ref.flatMap { $0.id == run.id ? nil : Scoring.paired(run, $0, suite: s) }
                    let h = r.perHand
                    let obj: EJ = .o([
                        ("answered", .i(r.answered)), ("total", .i(r.total)), ("complete", .b(r.isComplete)),
                        ("hands", .i(h?.hands ?? 0)), ("bb", .opt(h?.bbPer100, 2)), ("ci", .opt(h?.bbPer100CI, 2)),
                        ("mixed", .opt(h?.mixedBbPer100, 2)), ("mixedCI", .opt(h?.mixedBbPer100CI, 2)),
                        ("score", .n(r.overall.gtoScore, 2)), ("scoreCI", .n(r.overall.gtoScoreCI, 2)),
                        ("lossPot", .n(r.overall.meanEVLossPot, 5)), ("cost", run.kind == .baseline ? .null : .n(r.totalCost, 5)),
                        ("isReference", .b(ref?.id == run.id)),
                        ("diff", p.map { p in .o([("bb", diff(p.bbPer100)), ("mixed", diff(p.mixedBbPer100)), ("score", diff(p.score)),
                                                  ("lossPot", diff(p.lossPot, 5))]) } ?? .null),
                    ])
                    cellsByLabel[run.label, default: []].append(Cell(split: split, obj: obj, bb: h?.bbPer100, diff: p?.bbPer100))
                }
            }
            // Focus-model rows (variants + derived runs built from them) first, then other players.
            func isFocus(_ r: BenchmarkRun) -> Bool {
                if r.model == focusModel { return true }
                guard r.kind == .derived, let src = r.derived?.sources else { return false }
                let slug = String(focusModel.split(separator: "/").last ?? Substring(focusModel))
                return src.contains { $0.contains(slug) }
            }
            let rows: [EJ] = order.map { label in
                let run = reps[label]!
                let cells = cellsByLabel[label] ?? []
                let test = cells.first { $0.split == "test" }, dev = cells.first { $0.split == "dev" }
                // Confirmed: improves on the reference on dev and the held-out test difference excludes 0.
                let confirmed = isFocus(run) && (test?.diff).map { $0.significant && $0.mean < 0 } == true && (dev?.diff?.mean ?? 0) <= 0
                return .o(identity(run, catalog: catalog) + [("focus", .b(isFocus(run))), ("confirmed", .b(confirmed))]
                          + cells.map { ($0.split, $0.obj) })
            }
            experiments.append(.o([("root", .s(root)), ("rootKey", .s(keyOf[root] ?? root)), ("format", formatObj(splits[0].format)),
                                   ("mode", .s(splits[0].mode.rawValue)), ("focus", .s(focusModel)), ("focusName", .s(modelName(focusModel, catalog: catalog))),
                                   ("splits", .a(meta)), ("rows", .a(rows))]))
            log.append("  experiment: \(root) · \(splits.map { FormatPool.split($0.id).split! }.joined(separator: "/")) · \(rows.count) rows")
        }

        let manifest: EJ = .o([
            ("schema", .i(bundleSchemaVersion)),
            ("generatedAt", .s(iso(generatedAt))),
            ("generator", .s("Equilibrium · eqbench bench export --all")),
            ("spot", spotSummary),
            ("suites", .a(suiteObjs)),
            ("formats", .o([("columns", .a(columns)), ("rows", .a(formatRows))])),
            ("experiments", .a(experiments)),
            ("formatInfo", .a(GameFormat.allCases.map(formatObj))),
            ("variants", .a(DecisionVariants.all.map { v in .o([("id", .s(v.id)), ("summary", .s(v.summary))]) })),
            ("thresholds", .o([("handsMinDecisions", .i(minHandsDecisions)), ("preflopMinDecisions", .i(minPreflopDecisions))])),
            ("calibration", Findings.calibrationJSON(suites: allSuites, runs: runs, focus: focusModel, catalog: catalog)),
            ("agreement", Findings.agreementJSON(suites: allSuites, runs: runs, suiteKeys: keyOf, spotSuiteId: spot?.id, focus: focusModel,
                                                 catalog: catalog)),
        ])
        return Bundle(manifest: manifest, spotDocument: spotDoc, suiteDocuments: docs, log: log)
    }

    /// `<repo>/web/data` (see `defaultOutputURL`).
    public static func defaultOutputDirectory() -> URL { defaultOutputURL().deletingLastPathComponent() }
}

extension BenchCLI {
    /// Live catalog names/prices, best effort with a short timeout (the export must work offline).
    static func exportCatalog(_ o: Options, needed: Bool) async -> [String: BenchExport.CatalogEntry] {
        var catalog: [String: BenchExport.CatalogEntry] = [:]
        guard !o.flags.contains("no-catalog"), needed, let client = try? OpenRouterClient.fromStoredKey() else { return catalog }
        let models: [ModelInfo]? = await withTaskGroup(of: [ModelInfo]?.self) { g in
            g.addTask { try? await client.decisionModels() }
            g.addTask { try? await Task.sleep(nanoseconds: 10_000_000_000); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
        for m in models ?? [] { catalog[m.id] = .init(name: m.name, promptPricePerM: m.promptPricePerM) }
        print(models == nil ? "  catalog unavailable — using billed cost for prices" : "  catalog: \(catalog.count) decision models")
        return catalog
    }

    static func exportAll(_ o: Options) async throws {
        let suites = BenchStore.suites()
        let runs = BenchStore.runs()
        let catalog = await exportCatalog(o, needed: runs.contains { $0.kind == .decisionModel })
        let spotId = try o["spots"].map { try BenchStore.loadSuite($0).id }
        let b = BenchExport.bundle(suites: suites, runs: runs, spotSuiteId: spotId, focusModel: o["focus"] ?? BenchExport.defaultFocusModel,
                                   catalog: catalog)
        let dir = o["out-dir"].map { URL(fileURLWithPath: $0) } ?? BenchExport.defaultOutputDirectory()
        let pretty = o.flags.contains("pretty")
        let suitesDir = dir.appendingPathComponent("suites")
        // Stale per-suite files (suites renamed or without model runs any more) are removed.
        if let old = try? FileManager.default.contentsOfDirectory(at: suitesDir, includingPropertiesForKeys: nil) {
            let keep = Set(b.suiteDocuments.map { "\($0.key).json" })
            for u in old where u.pathExtension == "json" && !keep.contains(u.lastPathComponent) { try? FileManager.default.removeItem(at: u) }
        }
        func write(_ doc: EJ, _ name: String) throws {
            let url = dir.appendingPathComponent(name)
            try BenchExport.write(doc, to: url, pretty: pretty)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print("  wrote \(name) (\(size / 1024) KB)")
        }
        print("Exporting to \(dir.path)")
        for l in b.log { print(l) }
        if let d = b.spotDocument { try write(d, "results.json") }
        for (k, d) in b.suiteDocuments { try write(d, "suites/\(k).json") }
        try write(b.manifest, "bench.json")
        print("Done. Also run `eqbench arena export` for arena.json. Optional prose: \(dir.appendingPathComponent("notes.json").path)")
    }
}
