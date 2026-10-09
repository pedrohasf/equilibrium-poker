import Foundation
import LLMKit
import SolverKit

/// `eqbench bench ...` subcommands.
public enum BenchCLI {
    static let help = """
    eqbench bench — score decisions against solved GTO spots (EV loss vs. equilibrium).

    USAGE:
      eqbench bench generate [--decisions 60] [--streets river,turn] [--scenarios id,id] [--seed 1]
                             [--min-spread 0.02] [--per-solve 3] [--concurrency 2] [--name text] [--out file]
      eqbench bench suites                         List saved suites
      eqbench bench run --suite <id|file> --models a,b,c [--concurrency 8] [--reasoning low]
                        [--temperature 0] [--max-tokens 4000] [--limit N] [--fresh]
      eqbench bench baselines --suite <id|file>    Run the bot baselines (no API calls)
      eqbench bench report [--suite <id|file>]     Leaderboard (default: newest suite)
      eqbench bench show --suite <id> --decision d001   One decision: GTO, EVs and every answer
      eqbench bench prompt --suite <id> [--decision d001]  Print the exact LLM prompt

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
        case "prompt": try prompt(opts)
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
        guard !models.isEmpty else { throw BenchError("--models is required (comma separated OpenRouter ids)") }
        let client = try OpenRouterClient.fromStoredKey(maxConcurrent: o.int("concurrency") ?? 8)
        let options = ChatOptions(temperature: o.double("temperature"), maxTokens: o.int("max-tokens"), reasoningEffort: o["reasoning"])
        let players: [any DecisionMaker] = models.map { LLMDecisionMaker(model: $0, client: client, options: options) }
        try await execute(suite: suite, players: players, o: o)
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
        for line in PromptBuilder.historyLines(d) { print("  " + line) }
        print("")
        print(row(["Action", "GTO", "EV", "Loss %pot"], widths: [28, 6, 9, 9]))
        for (i, a) in d.actions.enumerated() {
            print(row([a.detailedLabel, BB.pct(d.strategy[i]), String(format: "%.2f", d.actionEVs[i]),
                       String(format: "%.1f%%", 100 * d.evLoss(i) / d.pot)], widths: [28, 6, 9, 9]))
        }
        print("")
        for run in BenchStore.runs(suiteId: suite.id) {
            guard let r = run.result(for: d.id) else { continue }
            let s = Scoring.score(d, choice: r.choice)
            let choice = r.choice.map { d.actions[$0].label } ?? "INVALID"
            print(row([run.label, choice, String(format: "-%.1f%% pot", s.evLossPot * 100)], widths: [34, 22, 14]))
        }
    }

    static func prompt(_ o: Options) throws {
        let suite = try suite(o)
        guard let d = suite.decision(o["decision"] ?? suite.decisions.first?.id ?? "") else { throw BenchError("No such decision") }
        print("── system ──\n\(PromptBuilder.system)\n\n── user ──\n\(PromptBuilder.user(d))")
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
        let w = [3, 34, 12, 15, 8, 6, 7, 8, 8, 8, 9]
        out.append(row(["#", "Player", "GTO score", "EV loss %pot", "bb/dec", "Best", "GTO-ok", "Blunder", "Invalid", "Latency", "Cost"],
                       widths: w, rightAlignFrom: 2))
        out.append(String(repeating: "─", count: w.reduce(0, +) + 2 * (w.count - 1)))
        for (i, r) in rows.enumerated() {
            let o = r.overall
            let name = r.label + (r.isBaseline ? " ·bot" : "") + (r.isComplete ? "" : " (\(r.answered)/\(r.total))")
            out.append(row([
                "\(i + 1)", name,
                String(format: "%.1f ±%.1f", o.gtoScore, o.gtoScoreCI),
                String(format: "%.2f%% ±%.2f", o.meanEVLossPot * 100, o.meanEVLossPotCI * 100),
                String(format: "%.3f", o.meanEVLoss),
                String(format: "%.0f%%", o.accuracy * 100),
                String(format: "%.0f%%", o.approvedRate * 100),
                String(format: "%.0f%%", o.blunderRate * 100),
                String(format: "%.0f%%", o.invalidRate * 100),
                r.isBaseline ? "–" : String(format: "%.1fs", r.meanLatency),
                r.isBaseline ? "–" : String(format: "$%.3f", r.totalCost),
            ], widths: w, rightAlignFrom: 2))
        }
        // Breakdowns.
        let streets = Street.allCases.filter { s in rows.contains { $0.byStreet[s.rawValue] != nil } }
        let types = DecisionType.allCases
        let bw = [34] + Array(repeating: 18, count: streets.count + types.count)
        out.append("")
        out.append("GTO score / EV loss (% pot) by street and decision type")
        out.append(row(["Player"] + streets.map { "\($0.title) (n=\(suite.countByStreet[$0] ?? 0))" }
                       + types.map { t in "\(t.title) (n=\(suite.decisions.filter { $0.decisionType == t }.count))" },
                       widths: bw, rightAlignFrom: 1))
        for r in rows {
            func cell(_ b: ScoreBucket?) -> String {
                guard let b, b.n > 0 else { return "–" }
                return String(format: "%5.1f / %5.2f%%", b.gtoScore, b.meanEVLossPot * 100)
            }
            out.append(row([r.label] + streets.map { cell(r.byStreet[$0.rawValue]) } + types.map { cell(r.byType[$0.rawValue]) },
                           widths: bw, rightAlignFrom: 1))
        }
        out.append("")
        out.append("GTO score = mean of 1 − (best − chosen)/(best − worst) × 100 · EV loss = best EV − chosen EV · "
                   + "Best = within \(String(format: "%.2g", Scoring.bestTolerance * 100))% pot of best · GTO-ok = GTO plays it ≥\(Int(Scoring.approvedFrequency * 100))% · "
                   + "Blunder = loss > \(Int(Scoring.blunderThreshold * 100))% pot · ± = 95% CI · invalid answers score as the worst action.")
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
