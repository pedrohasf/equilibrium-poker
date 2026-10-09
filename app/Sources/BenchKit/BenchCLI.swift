import Foundation
import OpenRouterKit
import SolverKit

/// `eqbench bench ...` subcommands.
public enum BenchCLI {
    static let help = """
    eqbench bench — score OpenRouter System One decision models against solved GTO spots (EV loss vs. equilibrium).

    USAGE:
      eqbench bench generate [--decisions 60] [--streets river,turn] [--scenarios id,id] [--seed 1]
                             [--min-spread 0.02] [--per-solve 3] [--concurrency 2] [--name text] [--out file]
      eqbench bench suites                         List saved suites
      eqbench bench run --suite <id|file> --models a,b,c [--concurrency 8] [--limit N] [--fresh]
                        Decision models only (e.g. typesafe/jev-1.13), validated against the live
                        catalog; each is asked one typed choice question. A `dm:` prefix is accepted.
      eqbench bench decision-models                List live OpenRouter decision models with prices
      eqbench bench baselines --suite <id|file>    Run the bot baselines (no API calls)
      eqbench bench report [--suite <id|file>]     Leaderboard (default: newest suite)
      eqbench bench show --suite <id> --decision d001   One decision: GTO, EVs and every answer
      eqbench bench state --suite <id> [--decision d001] [--model id]  Print the JSON state + question sent to decision models

    Streets: flop, turn, river (flop solves take minutes). Scenarios: \(Scenarios.all.map(\.id).joined(separator: ", ")).
    Suites and runs are stored in ~/Library/Application Support/Equilibrium/{suites,runs}. Runs resume automatically.
    """

    public static func run(_ args: [String]) async throws {
        let cmd = args.first ?? "help"
        let opts = Options(Array(args.dropFirst()))
        switch cmd {
        case "generate", "gen": try await generate(opts)
        case "suites", "list": listSuites()
        case "run": try await runModels(opts)
        case "baselines", "bots": try await runBaselines(opts)
        case "report", "leaderboard": try report(opts)
        case "show": try show(opts)
        case "state": try state(opts)
        case "decision-models", "dms": try await listDecisionModels()
        default: print(help)
        }
    }

    // MARK: Options

    struct Options {
        var values: [String: String] = [:]
        var flags: Set<String> = []

        init(_ args: [String]) {
            var i = 0
            while i < args.count {
                let a = args[i]
                guard a.hasPrefix("--") else { i += 1; continue }
                let key = String(a.dropFirst(2))
                if let eq = key.firstIndex(of: "=") {
                    values[String(key[..<eq])] = String(key[key.index(after: eq)...])
                } else if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                    values[key] = args[i + 1]
                    i += 1
                } else {
                    flags.insert(key)
                }
                i += 1
            }
        }

        subscript(_ k: String) -> String? { values[k] }
        func int(_ k: String) -> Int? { values[k].flatMap(Int.init) }
        func double(_ k: String) -> Double? { values[k].flatMap(Double.init) }
        func list(_ k: String) -> [String] {
            (values[k] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    static func suite(_ o: Options) throws -> BenchmarkSuite {
        if let s = o["suite"] { return try BenchStore.loadSuite(s) }
        guard let newest = BenchStore.suites().first else { throw BenchError("No suites yet. Run `eqbench bench generate` first.") }
        return newest
    }

    // MARK: Commands

    static func generate(_ o: Options) async throws {
        var p = SuiteParameters()
        if let n = o.int("decisions") { p.decisions = n }
        if let s = o["streets"] { p.streets = Street.parseList(s) }
        guard !p.streets.isEmpty else { throw BenchError("--streets must list flop, turn and/or river") }
        p.scenarioIds = o.list("scenarios")
        for id in p.scenarioIds where Scenarios.named(id) == nil { throw BenchError("Unknown scenario '\(id)'") }
        if let s = o["seed"].flatMap(UInt64.init) { p.seed = s }
        if let x = o.double("min-spread") { p.minEVSpread = x }
        if let x = o.int("per-solve") { p.decisionsPerSolve = max(1, x) }
        if let x = o.int("concurrency") { p.concurrency = max(1, x) }
        if let x = o.double("target") { p.targetExploitability = x }
        if p.streets.contains(.flop) {
            print("warning: flop subgames take minutes each to solve (lean tree: one 33% bet, one raise).")
        }
        print("Generating \(p.decisions) decisions · streets \(p.streets.map(\.rawValue).joined(separator: ",")) · seed \(p.seed)")
        fflush(stdout)
        let suite = try await SuiteGenerator.generate(p, name: o["name"]) { g in
            let line = String(format: "\r  solves %3d · decisions %3d/%d · %5.1fs", g.solvesDone, g.decisions, g.target, g.elapsed)
            FileHandle.standardOutput.write(Data(line.utf8))
        }
        print("")
        let url = try BenchStore.save(suite)
        if let out = o["out"] { try BenchStore.save(suite, to: URL(fileURLWithPath: out)) }
        print("Saved suite \(suite.id)")
        print("  \(suite.decisions.count) decisions from \(suite.solves) solves in \(String(format: "%.1f", suite.generationSeconds))s → \(url.path)")
        let streets = Street.allCases.compactMap { s in suite.countByStreet[s].map { "\(s.rawValue) \($0)" } }
        print("  by street: \(streets.joined(separator: " · "))")
        let facing = suite.decisions.filter(\.facingBet).count
        print("  facing a bet: \(facing) · first to act / checked to: \(suite.decisions.count - facing)")
    }

    static func listSuites() {
        let suites = BenchStore.suites()
        guard !suites.isEmpty else { print("No suites. Run `eqbench bench generate`."); return }
        let runs = BenchStore.runs()
        print(row(["ID", "Decisions", "Streets", "Runs", "Created"], widths: [40, 9, 14, 5, 16]))
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        for s in suites {
            let streets = Street.allCases.compactMap { st in s.countByStreet[st].map { "\(st.rawValue.prefix(1))\($0)" } }.joined(separator: " ")
            print(row([s.id, "\(s.decisions.count)", streets, "\(runs.filter { $0.suiteId == s.id }.count)", df.string(from: s.createdAt)],
                      widths: [40, 9, 14, 5, 16]))
        }
    }

    static func runModels(_ o: Options) async throws {
        let suite = try suite(o)
        let models = o.list("models")
        guard !models.isEmpty else { throw BenchError("--models is required (comma separated decision-model ids)") }
        let client = try OpenRouterClient.fromStoredKey(maxConcurrent: o.int("concurrency") ?? 8)
        let catalog: Set<String>
        do {
            catalog = Set(try await client.decisionModels().map(\.id))
        } catch {
            throw BenchError("Could not load the decision-model catalog: \(error.localizedDescription)")
        }
        let ids = try resolveModels(models, decisionCatalog: catalog)
        let players: [any DecisionMaker] = ids.map { DecisionModelMaker(model: $0, provider: client) }
        print("  \(ids.count) decision model(s) · state v\(DecisionStateBuilder.version)")
        try await execute(suite: suite, players: players, o: o)
    }

    /// Strips an optional `dm:` prefix and checks every id against the live decision catalog.
    /// Throws listing the unknown ids (and the available ones) if any is not a decision model.
    public static func resolveModels(_ raw: [String], decisionCatalog: Set<String>) throws -> [String] {
        let ids = raw.map { $0.hasPrefix("dm:") ? String($0.dropFirst(3)) : $0 }
        let unknown = ids.filter { !decisionCatalog.contains($0) }
        guard unknown.isEmpty else {
            let available = decisionCatalog.sorted().joined(separator: ", ")
            throw BenchError("Not an OpenRouter decision model: \(unknown.joined(separator: ", ")). "
                             + "Only System One decision models can be benchmarked"
                             + (available.isEmpty ? " (the decision catalog is empty)." : ". Available: \(available)")
                             + " — see `eqbench bench decision-models`.")
        }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    static func listDecisionModels() async throws {
        let client = try OpenRouterClient.fromStoredKey()
        let models = try await client.decisionModels().sorted { $0.id < $1.id }
        guard !models.isEmpty else { print("The decision-model catalog is empty."); return }
        let w = [44, 30, 9, 12, 9]
        print(row(["ID", "Name", "Context", "Input $/M", "Suggested"], widths: w))
        for m in models {
            print(row([m.id, m.name, m.contextLength.map { "\($0 / 1000)k" } ?? "–",
                       m.promptPricePerM.map { String(format: "$%.3f", $0) } ?? "?",
                       DecisionRoster.suggested.contains(m.id) ? "yes" : ""], widths: w))
        }
        print("\nOutput is free for decision models; cost ≈ input tokens × input price "
              + "(~\(BenchStore.suites().first.map { s in s.decisions.isEmpty ? 0 : s.decisions.reduce(0) { $0 + DecisionStateBuilder.estimatedInputTokens($1) } / s.decisions.count } ?? 0) tokens per decision on the newest suite).")
    }

    static func runBaselines(_ o: Options) async throws {
        let suite = try suite(o)
        try await execute(suite: suite, players: Baseline.allCases, o: o)
    }

    static func execute(suite: BenchmarkSuite, players: [any DecisionMaker], o: Options) async throws {
        print("Suite \(suite.id) · \(suite.decisions.count) decisions · \(players.count) player(s)")
        fflush(stdout)
        let state = ProgressPrinter(names: players.map(\.id))
        let runs = try await BenchmarkRunner.run(suite: suite, players: players, concurrency: o.int("concurrency") ?? 8,
                                                 resume: !o.flags.contains("fresh"), limit: o.int("limit")) { p in
            state.update(p)
        }
        state.finish()
        printLeaderboard(suite: suite, rows: Scoring.leaderboard(suite: suite, runs: runs))
    }

    static func report(_ o: Options) throws {
        let suite = try suite(o)
        let runs = BenchStore.runs(suiteId: suite.id)
        print("Suite \(suite.id) · \(suite.name)")
        let rows = Scoring.leaderboard(suite: suite, runs: runs)
        guard !rows.isEmpty else { print("No runs yet. Try `eqbench bench baselines --suite \(suite.id)`."); return }
        printLeaderboard(suite: suite, rows: rows)
    }

    static func show(_ o: Options) throws {
        let suite = try suite(o)
        guard let d = suite.decision(o["decision"] ?? suite.decisions.first?.id ?? "") else { throw BenchError("No such decision") }
        print("\(d.id) · \(d.scenarioName) · \(d.headline)")
        print("Villain held \(d.villainCards) · equity \(BB.pct(d.equity)) · pot \(BB.fmt(d.pot)) bb · solver \(String(format: "%.2f", d.exploitability))% pot")
        for line in d.historyLines() { print("  " + line) }
        print("")
        print(row(["Action", "GTO", "EV", "Loss %pot"], widths: [28, 6, 9, 9]))
        for (i, a) in d.actions.enumerated() {
            print(row([a.detailedLabel, BB.pct(d.strategy[i]), String(format: "%.2f", d.actionEVs[i]),
                       String(format: "%.1f%%", 100 * d.evLoss(i) / d.pot)], widths: [28, 6, 9, 9]))
        }
        print("")
        for run in BenchStore.runs(suiteId: suite.id) {
            guard let r = run.result(for: d.id) else { continue }
            let s = Scoring.score(d, result: r, run: run)
            let choice = r.choice.map { d.actions[$0].label } ?? "INVALID"
            var cols = [run.label, choice, String(format: "-%.1f%% pot", s.evLossPot * 100)]
            if let p = r.actionProbabilities {
                cols.append("p=[" + p.map { String(format: "%.2f", $0) }.joined(separator: " ") + "]")
                if let m = s.mixedEVLossPot { cols.append(String(format: "mixed -%.1f%%", m * 100)) }
                if let tv = s.tvDistance { cols.append(String(format: "TV %.2f", tv)) }
                if let c = r.confidence { cols.append(String(format: "conf %.2f", c)) }
            }
            print(row(cols, widths: [34, 22, 14, 30, 14, 8, 10]))
        }
    }

    static func state(_ o: Options) throws {
        let suite = try suite(o)
        guard let d = suite.decision(o["decision"] ?? suite.decisions.first?.id ?? "") else { throw BenchError("No such decision") }
        print("// \(d.id) · \(d.headline) · state v\(DecisionStateBuilder.version) · ~\(DecisionStateBuilder.estimatedInputTokens(d)) input tokens")
        print("// POST https://openrouter.ai/api/alpha/decisions (question id is never shown to the model)")
        print(DecisionStateBuilder.requestBody(d, model: o["model"] ?? DecisionRoster.suggested[0]).prettyText)
    }

    // MARK: Output

    static func row(_ cols: [String], widths: [Int], rightAlignFrom: Int = 99) -> String {
        zip(cols, widths).enumerated().map { i, cw in
            let (c, w) = cw
            let s = c.count > w ? String(c.prefix(w - 1)) + "…" : c
            let pad = String(repeating: " ", count: max(0, w - s.count))
            return i >= rightAlignFrom ? pad + s : s + pad
        }.joined(separator: "  ")
    }

    public static func leaderboardText(suite: BenchmarkSuite, rows: [ModelScore]) -> String {
        var out: [String] = []
        let w = [3, 34, 12, 15, 8, 6, 7, 8, 8, 13, 9, 7, 8, 9]
        out.append(row(["#", "Player", "GTO score", "EV loss %pot", "bb/dec", "Best", "GTO-ok", "Blunder", "Invalid",
                        "Mixed %pot", "TV dist", "P(best)", "Latency", "Cost"],
                       widths: w, rightAlignFrom: 2))
        let rule = String(repeating: "─", count: w.reduce(0, +) + 2 * (w.count - 1))
        out.append(rule)
        let rank = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0 + 1) })
        for kind in PlayerKind.allCases.sorted(by: { $0.order < $1.order }) {
            let group = rows.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            out.append("\(kind.groupTitle) (\(group.count))")
            for r in group {
                let o = r.overall
                let name = r.label + (r.isComplete ? "" : " (\(r.answered)/\(r.total))")
                func opt(_ x: Double?, _ f: String, _ scale: Double = 1) -> String { x.map { String(format: f, $0 * scale) } ?? "–" }
                out.append(row([
                    "\(rank[r.id] ?? 0)", name,
                    String(format: "%.1f ±%.1f", o.gtoScore, o.gtoScoreCI),
                    String(format: "%.2f%% ±%.2f", o.meanEVLossPot * 100, o.meanEVLossPotCI * 100),
                    String(format: "%.3f", o.meanEVLoss),
                    String(format: "%.0f%%", o.accuracy * 100),
                    String(format: "%.0f%%", o.approvedRate * 100),
                    String(format: "%.0f%%", o.blunderRate * 100),
                    String(format: "%.0f%%", o.invalidRate * 100),
                    o.meanMixedEVLossPot.map { String(format: "%.2f%% ±%.2f", $0 * 100, (o.meanMixedEVLossPotCI ?? 0) * 100) } ?? "–",
                    opt(o.meanTVDistance, "%.3f"),
                    opt(o.meanBestActionProbability, "%.0f%%", 100),
                    r.isBaseline ? "–" : String(format: "%.1fs", r.meanLatency),
                    r.isBaseline ? "–" : String(format: "$%.3f", r.totalCost),
                ], widths: w, rightAlignFrom: 2))
            }
        }
        // Breakdowns.
        let streets = Street.allCases.filter { s in rows.contains { $0.byStreet[s.rawValue] != nil } }
        let types = DecisionType.allCases
        let bw = [34] + Array(repeating: 18, count: streets.count + types.count)
        func breakdown(_ title: String, _ subset: [ModelScore], _ cell: (ScoreBucket?) -> String) {
            guard !subset.isEmpty else { return }
            out.append("")
            out.append(title)
            out.append(row(["Player"] + streets.map { "\($0.title) (n=\(suite.countByStreet[$0] ?? 0))" }
                           + types.map { t in "\(t.title) (n=\(suite.decisions.filter { $0.decisionType == t }.count))" },
                           widths: bw, rightAlignFrom: 1))
            for r in subset {
                out.append(row([r.label] + streets.map { cell(r.byStreet[$0.rawValue]) } + types.map { cell(r.byType[$0.rawValue]) },
                               widths: bw, rightAlignFrom: 1))
            }
        }
        breakdown("GTO score / EV loss (% pot) by street and decision type", rows) { b in
            guard let b, b.n > 0 else { return "–" }
            return String(format: "%5.1f / %5.2f%%", b.gtoScore, b.meanEVLossPot * 100)
        }
        breakdown("Mixed EV loss (% pot) / TV distance by street and decision type", rows.filter(\.hasDistribution)) { b in
            guard let b, let m = b.meanMixedEVLossPot else { return "–" }
            return String(format: "%5.2f%% / %.2f", m * 100, b.meanTVDistance ?? 0)
        }
        out.append("")
        out.append("GTO score = mean of 1 − (best − chosen)/(best − worst) × 100 · EV loss = best EV − chosen EV · "
                   + "Best = within \(String(format: "%.2g", Scoring.bestTolerance * 100))% pot of best · GTO-ok = GTO plays it ≥\(Int(Scoring.approvedFrequency * 100))% · "
                   + "Blunder = loss > \(Int(Scoring.blunderThreshold * 100))% pot · ± = 95% CI · invalid answers score as the worst action.")
        out.append("Players with action probabilities (decision models, sampled GTO): Mixed = Σ p(a)·loss(a), the EV lost playing the "
                   + "reported distribution · TV dist = ½Σ|p − GTO| for hero's hand (0 = equilibrium mix, 1 = disjoint) · "
                   + "P(best) = mean probability on the best-EV action(s) (calibration).")
        return out.joined(separator: "\n")
    }

    static func printLeaderboard(suite: BenchmarkSuite, rows: [ModelScore]) {
        print("")
        print(leaderboardText(suite: suite, rows: rows))
    }
}

/// Thread-safe single-line progress for the CLI.
final class ProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var state: [String: RunProgress] = [:]
    private let names: [String]
    private var lastPrint = Date.distantPast

    init(names: [String]) { self.names = names }

    func update(_ p: RunProgress) {
        lock.lock()
        defer { lock.unlock() }
        state[p.model] = p
        guard state.count == names.count, Date().timeIntervalSince(lastPrint) > 0.2 || p.done == p.total else { return }
        lastPrint = Date()
        let done = state.values.reduce(0) { $0 + $1.done }
        let total = state.values.reduce(0) { $0 + $1.total }
        let cost = state.values.reduce(0) { $0 + $1.cost }
        let invalid = state.values.reduce(0) { $0 + $1.invalid }
        let line = String(format: "\r  answered %4d/%-4d · invalid %d · cost $%.4f   ", done, total, invalid, cost)
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        print("")
        for n in names {
            guard let p = state[n], let e = p.lastError else { continue }
            print("  \(n): \(p.invalid) invalid · last error: \(e)")
        }
    }
}
