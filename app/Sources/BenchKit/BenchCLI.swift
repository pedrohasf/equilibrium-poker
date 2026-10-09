import Foundation
import OpenRouterKit
import SolverKit

/// `eqbench bench ...` subcommands.
public enum BenchCLI {
    static var help: String { """
    eqbench bench — score OpenRouter System One decision models against solved GTO spots (EV loss vs. equilibrium).

    USAGE:
      eqbench bench generate --mode hands [--format cash|mtt40|mtt20|spin] [--hands 120] [--per-solve 3] [--seed 1] [--scenarios id,id] [--min-spread 0]
                             [--target 0.75] [--max-iter 150] [--flop-bet 33] [--flop-bet-ip 33] [--turn-bet 66]
                             [--river-bet 75] [--raise-limit 1] [--name text] [--out file]
                        Realistic suite: flop solves from preflop ranges; K hands dealt per solve and played to the
                        end following GTO; every decision of both players on every street is recorded (grouped by hand).
                        Scenarios are weighted towards BTN/CO vs BB single-raised pots. ≈ 30 s per solve.
      eqbench bench generate [--mode spots] [--decisions 60] [--streets river,turn] [--scenarios id,id] [--seed 1]
                             [--min-spread 0.02] [--per-solve 3] [--concurrency 2] [--name text] [--out file]
                        Legacy suite: independent turn/river spots from preflop ranges, trivial spots skipped.
      eqbench bench generate --mode preflop [--format cash|mtt40|mtt20|spin] [--hands 300] [--seed 1]
                        Heads-up preflop suite (blind vs blind / spin HU) from the preflop solver: every preflop
                        decision of each dealt hand. Reported as preflop bb/100, separately from postflop suites.
      eqbench bench suites                         List saved suites
      eqbench bench split --suite <id> [--dev 0.5] [--seed 1]
                        Split a suite into <id>-dev and <id>-test (by hand for hands suites, by solve otherwise):
                        tune on dev, confirm on test. (Or generate two suites with different --seed.)
      eqbench bench run --suite <id|file> --models a,b,c [--variant v2[,eq,...]] [--concurrency 8] [--limit N] [--fresh]
                        Decision models only (e.g. typesafe/jev-1.13), validated against the live catalog. Each
                        (model, variant) pair is its own run: "typesafe/jev-1.13 [eq]". Prints estimated and running cost.
      eqbench bench variants                       List state/question variants
      eqbench bench decision-models                List live OpenRouter decision models with prices
      eqbench bench baselines --suite <id|file>    Run the bot baselines (no API calls)
      eqbench bench report [--suite <id|file>]     Leaderboard (default: newest suite)
      eqbench bench compare [--suite <id>] [--ref <run>] [--min-spread x]
                        Compact table of every run (score, EV loss, mixed loss, bb/100, cost) plus the paired
                        difference vs a reference run with 95% CIs (paired over decisions; bb/100 over hands).
                        --min-spread restricts to decisions whose EV spread ≥ x · pot.
      eqbench bench synth --suite <id> ensemble --runs a,b[,c] [--weights 2,1] [--name text]
      eqbench bench synth --suite <id> temper --run a --tau 0.5,2,4,inf
      eqbench bench synth --suite <id> guardrail --run a [--margin 0.05] [--equity narrowed|preflop]
                        Post-hoc players from stored answers (no API cost), saved as derived runs. <run> = run id,
                        label ("typesafe/jev-1.13 [eq]") or a unique substring.
      eqbench bench show --suite <id> --decision d001   One decision: GTO, EVs and every answer
      eqbench bench state --suite <id> [--decision d001] [--variant v2] [--model id]
                        Print the exact JSON request sent to decision models
      eqbench bench export [--suite <id|file>] [--out web/data/results.json] [--pretty] [--no-catalog]
                        One JSON for the static results site: suite metadata, scored leaderboard
                        (Scoring), breakdowns, cost/latency and every decision with all answers.
      eqbench bench export --all [--out-dir web/data] [--spots <suite>] [--focus openai/gpt-6-luna-decisions]
                             [--pretty] [--no-catalog]
                        Everything for the website: results.json (spot suite, default: the spots suite with the most
                        decision-model runs), bench.json (every published suite, per-format bb/100, dev/test variant
                        experiments for --focus) and suites/<key>.json (per-decision data for the spot explorer).
                        Pair with `eqbench arena export` (arena.json).

      eqbench bench formats [--model substring] [--variant v] [--published]
                        Cross-format summary: postflop bb/100 lost (± 95% CI, hands pooled over every hands suite of
                        the format; hands shared with dev/test splits counted once) for each model/variant, per game
                        format. --published: only the suites the website shows (hands ≥ 50, preflop ≥ 100 decisions).

    Formats (hands mode --format): \(GameFormat.allCases.map(\.rawValue).joined(separator: ", ")) — one format per suite; trees
    are chosen per scenario SPR (explicit all-in when SPR < 8, two flop sizes when SPR < 3).
    Variants: \(DecisionVariants.ids.joined(separator: ", ")) (see `eqbench bench variants`).
    Scenarios: \(Scenarios.every.map(\.id).joined(separator: ", ")).
    Suites and runs are stored in ~/Library/Application Support/Equilibrium/{suites,runs}. Runs resume automatically.
    """ }

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
        case "export": if opts.flags.contains("all") { try await exportAll(opts) } else { try await export(opts) }
        case "decision-models", "dms": try await listDecisionModels()
        case "variants": listVariants()
        case "compare": try compare(opts)
        case "split": try split(opts)
        case "synth": try synth(Array(args.dropFirst()), opts)
        case "formats": print(formatsText(model: opts["model"], variant: opts["variant"], publishedOnly: opts.flags.contains("published")))
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
        let mode = SuiteMode(rawValue: o["mode"] ?? "spots")
        guard let mode else { throw BenchError("--mode must be spots or hands") }
        if mode == .hands { return try await generateHands(o) }
        if mode == .preflop { return try await generatePreflop(o) }
        var p = SuiteParameters()
        if let n = o.int("decisions") { p.decisions = n }
        if let s = o["streets"] { p.streets = Street.parseList(s).filter(\.isPostflop) }
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

    static func generateHands(_ o: Options) async throws {
        var tree = HandsTreeConfig.standard
        if let x = o.double("target") { tree.targetExploitability = x }
        if let x = o.int("max-iter") { tree.maxIterations = max(1, x) }
        if let x = o["flop-bet"] { tree.flopBetOOP = x; tree.flopBetIP = o["flop-bet-ip"] ?? x }
        if let x = o["flop-bet-ip"] { tree.flopBetIP = x }
        if let x = o["turn-bet"] { tree.turnBet = x }
        if let x = o["river-bet"] { tree.riverBet = x }
        if let x = o.int("raise-limit") { tree.raiseLimit = max(0, x) }
        let ids = o.list("scenarios")
        for id in ids where Scenarios.named(id) == nil { throw BenchError("Unknown scenario '\(id)'") }
        guard let format = GameFormat(rawValue: o["format"] ?? "cash") else {
            throw BenchError("--format must be one of \(GameFormat.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let treeFlags = ["flop-bet", "flop-bet-ip", "turn-bet", "river-bet", "raise-limit"]
        let custom = treeFlags.contains { o[$0] != nil }
        let p = SuiteParameters.hands(o.int("hands") ?? 120, handsPerSolve: max(1, o.int("per-solve") ?? 3), format: format, scenarioIds: ids,
                                      seed: o["seed"].flatMap(UInt64.init) ?? 1, tree: custom ? tree : nil,
                                      targetExploitability: tree.targetExploitability, maxIterations: tree.maxIterations,
                                      minEVSpread: o.double("min-spread") ?? 0)
        let scen = p.scenarios
        guard !scen.isEmpty else { throw BenchError("No scenarios for format \(format.rawValue)") }
        let solves = ((p.hands ?? 0) + (p.handsPerSolve ?? 1) - 1) / (p.handsPerSolve ?? 1)
        print("Generating \(p.hands ?? 0) hands (\(solves) flop solves × \(p.handsPerSolve ?? 0) hands) · \(format.title) · seed \(p.seed)")
        print("  scenarios: " + scen.map { s in "\(s.id) (SPR \(String(format: "%.1f", s.stack / s.pot)), w \(SuiteGenerator.scenarioWeights[s.id] ?? 0.1))" }
            .joined(separator: " · "))
        print("  tree: " + (custom ? tree.summary : "by SPR — " + Set(scen.map { HandsTreeConfig.forSPR($0.stack / $0.pot).summary }).sorted().joined(separator: " | ")))
        print("  solve to \(String(format: "%.2g", tree.targetExploitability))% pot or \(tree.maxIterations) iterations · ≈ 20–40 s per solve")
        fflush(stdout)
        let suite = try await SuiteGenerator.generateHands(p, name: o["name"]) { g in
            guard let r = g.last else { return }
            let eta = g.eta.map { " · ETA \(Self.duration($0))" } ?? ""
            let head = String(format: "  solve %3d/%d  ", g.solvesDone, g.solvesTotal) + r.scenarioId.padding(toLength: 11, withPad: " ", startingAt: 0)
            print(head + " \(r.board)  " + String(format: "%.2f%% pot  %3d it  %5.1fs + %4.1fs sampling  +%2d decisions (%d total, %d hands)  ",
                                                  r.exploitability, r.iterations, r.solveSeconds, r.sampleSeconds, r.decisions, g.decisions, g.hands)
                  + Self.duration(g.elapsed) + eta)
            fflush(stdout)
        }
        let url = try BenchStore.save(suite)
        if let out = o["out"] { try BenchStore.save(suite, to: URL(fileURLWithPath: out)) }
        print("Saved suite \(suite.id)")
        print("  \(suite.handIds.count) hands · \(suite.decisions.count) decisions from \(suite.solves) solves in \(Self.duration(suite.generationSeconds)) → \(url.path)")
        printSuiteStats(suite)
    }

    static func generatePreflop(_ o: Options) async throws {
        guard let format = GameFormat(rawValue: o["format"] ?? "cash") else {
            throw BenchError("--format must be one of \(GameFormat.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let p = SuiteParameters.preflop(o.int("hands") ?? 300, format: format, seed: o["seed"].flatMap(UInt64.init) ?? 1,
                                        minEVSpread: o.double("min-spread") ?? 0)
        print("Generating \(p.hands ?? 0) heads-up preflop hands · \(format.title) · seed \(p.seed)")
        print("  depths: " + SuiteGenerator.preflopSpecs(format).map(\.name).joined(separator: " · "))
        fflush(stdout)
        let suite = try await SuiteGenerator.generatePreflop(p, name: o["name"]) { g in
            if let m = g.message { print("  " + m) } else {
                print("  hands \(g.hands)/\(g.total) · \(g.decisions) decisions · \(Self.duration(g.elapsed))")
            }
            fflush(stdout)
        }
        let url = try BenchStore.save(suite)
        if let out = o["out"] { try BenchStore.save(suite, to: URL(fileURLWithPath: out)) }
        print("Saved suite \(suite.id)")
        print("  \(suite.handIds.count) hands · \(suite.decisions.count) decisions in \(Self.duration(suite.generationSeconds)) → \(url.path)")
        printSuiteStats(suite)
    }

    static func printSuiteStats(_ suite: BenchmarkSuite) {
        let streets = Street.allCases.compactMap { s in suite.countByStreet[s].map { "\(s.rawValue) \($0)" } }
        print("  by street: \(streets.joined(separator: " · "))")
        let facing = suite.decisions.filter(\.facingBet).count
        print("  facing a bet: \(facing) · first to act / checked to: \(suite.decisions.count - facing)")
        let scen = suite.countByScenario.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }
        print("  by scenario: \(scen.joined(separator: " · "))")
        let trivial = suite.decisions.filter { $0.evSpreadPot < 0.02 }.count
        print("  EV spread < 2% pot (near-trivial): \(trivial) of \(suite.decisions.count)")
        if let recs = suite.solveRecords, !recs.isEmpty {
            let ex = recs.map(\.exploitability), t = recs.map(\.solveSeconds), sm = recs.map(\.sampleSeconds)
            print(String(format: "  solves: exploitability mean %.2f%% / max %.2f%% pot · solve time mean %.1fs / max %.1fs · sampling mean %.1fs",
                         ex.reduce(0, +) / Double(ex.count), ex.max()!, t.reduce(0, +) / Double(t.count), t.max()!,
                         sm.reduce(0, +) / Double(sm.count)))
        }
    }

    static func duration(_ s: Double) -> String {
        s < 60 ? String(format: "%.0fs", s) : s < 3600 ? String(format: "%dm%02ds", Int(s) / 60, Int(s) % 60)
            : String(format: "%dh%02dm", Int(s) / 3600, Int(s) % 3600 / 60)
    }

    static func listVariants() {
        for v in DecisionVariants.all {
            print("\(v.id.padding(toLength: 9, withPad: " ", startingAt: 0)) \(v.summary)\(v.id == DecisionVariants.defaultId ? " (default)" : "")")
        }
        if let s = BenchStore.suites().first, let d = s.decisions.first(where: \.facingBet) ?? s.decisions.first {
            print("\nApprox. input tokens per request on \(s.id) \(d.id): "
                  + DecisionVariants.all.map { "\($0.id) \($0.estimatedInputTokens(d))" }.joined(separator: " · "))
        }
    }

    static func listSuites() {
        let suites = BenchStore.suites()
        guard !suites.isEmpty else { print("No suites. Run `eqbench bench generate`."); return }
        let runs = BenchStore.runs()
        print(row(["ID", "Mode", "Decisions", "Streets", "Runs", "Created"], widths: [40, 12, 9, 16, 5, 16]))
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        for s in suites {
            let streets = Street.allCases.compactMap { st in s.countByStreet[st].map { "\(st.rawValue.prefix(1))\($0)" } }.joined(separator: " ")
            let mode = s.isHands ? "\(s.format.rawValue)\(s.mode == .preflop ? " pre" : "") \(s.handIds.count)h" : "spots"
            print(row([s.id, mode, "\(s.decisions.count)", streets, "\(runs.filter { $0.suiteId == s.id }.count)", df.string(from: s.createdAt)],
                      widths: [40, 12, 9, 16, 5, 16]))
        }
    }

    static func runModels(_ o: Options) async throws {
        let suite = try suite(o)
        let models = o.list("models")
        guard !models.isEmpty else { throw BenchError("--models is required (comma separated decision-model ids)") }
        let variants = try resolveVariants(o.list("variant"))
        let client = try OpenRouterClient.fromStoredKey(maxConcurrent: o.int("concurrency") ?? 8)
        let catalog: [ModelInfo]
        do {
            catalog = try await client.decisionModels()
        } catch {
            throw BenchError("Could not load the decision-model catalog: \(error.localizedDescription)")
        }
        let ids = try resolveModels(models, decisionCatalog: Set(catalog.map(\.id)))
        var players: [any DecisionMaker] = []
        for id in ids { for v in variants { players.append(DecisionModelMaker(model: id, provider: client, variant: v)) } }
        print("  \(ids.count) decision model(s) × \(variants.count) variant(s): \(variants.map(\.id).joined(separator: ", "))")

        // Pre-run cost estimate for the decisions each run still has to answer.
        let todo = Array(suite.decisions.prefix(o.int("limit") ?? suite.decisions.count))
        var estTotal = 0.0
        var unknown = false
        for id in ids {
            let price = catalog.first { $0.id == id }?.promptPricePerM.map { $0 / 1_000_000 }
            for v in variants {
                let runId = BenchmarkRun.makeId(suiteId: suite.id, model: id, variant: v.id)
                let answered = o.flags.contains("fresh") ? [] : (BenchStore.loadRun(id: runId)?.answeredIds ?? [])
                let open = todo.filter { !answered.contains($0.id) }
                let e = CostEstimator.estimate(decisions: open, promptPrice: price, variant: v)
                if let u = e.usd { estTotal += u } else { unknown = true }
                print("    \(id) [\(v.id)]: \(open.count) to answer · ~\(e.promptTokens / max(1, open.count)) tokens each · est. "
                      + (e.usd.map { String(format: "$%.4f", $0) } ?? "price unknown"))
            }
        }
        print(String(format: "  estimated cost: $%.4f%@", estTotal, unknown ? " + unknown-price models" : ""))
        try await execute(suite: suite, players: players, o: o, estimatedCost: estTotal)
    }

    /// `--variant a,b` → variants (default `v2`); throws on unknown ids.
    public static func resolveVariants(_ raw: [String]) throws -> [DecisionVariant] {
        let ids = raw.isEmpty ? [DecisionVariants.defaultId] : raw
        return try ids.map { id in
            guard let v = DecisionVariants.named(id) else {
                throw BenchError("Unknown variant '\(id)'. Available: \(DecisionVariants.ids.joined(separator: ", "))")
            }
            return v
        }
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

    static func execute(suite: BenchmarkSuite, players: [any DecisionMaker], o: Options, estimatedCost: Double? = nil) async throws {
        print("Suite \(suite.id) · \(suite.decisions.count) decisions · \(players.count) player(s)")
        fflush(stdout)
        let state = ProgressPrinter(names: players.map { BenchmarkRun.makeId(suiteId: suite.id, model: $0.id, variant: $0.variant) },
                                    perPlayer: min(suite.decisions.count, o.int("limit") ?? suite.decisions.count))
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
        print("  mode \(suite.mode.rawValue) · format \(suite.format.title)" + (suite.isHands ? " · \(suite.handIds.count) hands" : ""))
        let rows = Scoring.leaderboard(suite: suite, runs: runs)
        guard !rows.isEmpty else { print("No runs yet. Try `eqbench bench baselines --suite \(suite.id)`."); return }
        printLeaderboard(suite: suite, rows: rows)
    }

    static func show(_ o: Options) throws {
        let suite = try suite(o)
        guard let d = suite.decision(o["decision"] ?? suite.decisions.first?.id ?? "") else { throw BenchError("No such decision") }
        print("\(d.id) · \(d.scenarioName) · \(d.headline)" + (d.handId.map { " · hand \($0) #\((d.handSeq ?? 0) + 1)" } ?? ""))
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
            for part in r.parts ?? [] {
                let what = part.pTrue.map { String(format: "P(true)=%.2f", $0) }
                    ?? part.probabilities.map { "p=[" + $0.map { String(format: "%.2f", $0) }.joined(separator: " ") + "]" } ?? "no answer"
                print("      · \(part.id): \(part.choice.map { d.actions.indices.contains($0) ? d.actions[$0].label : "?" } ?? "–") \(what)")
            }
        }
    }

    static func state(_ o: Options) throws {
        let suite = try suite(o)
        guard let d = suite.decision(o["decision"] ?? suite.decisions.first?.id ?? "") else { throw BenchError("No such decision") }
        let v = try resolveVariants(o.list("variant")).first ?? DecisionVariants.default
        print("// \(d.id) · \(d.headline) · variant \(v.id) (state v\(DecisionStateBuilder.version)) · ~\(v.estimatedInputTokens(d)) input tokens")
        if let h = d.handId { print("// hand \(h) · decision \((d.handSeq ?? 0) + 1) of the hand") }
        print("// POST https://openrouter.ai/api/alpha/decisions (question ids are never shown to the model)")
        print(v.requestBody(d, model: o["model"] ?? DecisionRoster.suggested[0]).prettyText)
    }

    static func export(_ o: Options) async throws {
        let suite = try suite(o)
        let runs = BenchStore.runs(suiteId: suite.id)
        var catalog: [String: BenchExport.CatalogEntry] = [:]
        if !o.flags.contains("no-catalog"), runs.contains(where: { $0.kind == .decisionModel }),
           let client = try? OpenRouterClient.fromStoredKey() {
            // Best effort with a short timeout: the export must work offline.
            let models: [ModelInfo]? = await withTaskGroup(of: [ModelInfo]?.self) { g in
                g.addTask { try? await client.decisionModels() }
                g.addTask { try? await Task.sleep(nanoseconds: 10_000_000_000); return nil }
                let first = await g.next() ?? nil
                g.cancelAll()
                return first
            }
            for m in models ?? [] { catalog[m.id] = .init(name: m.name, promptPricePerM: m.promptPricePerM) }
            print(models == nil ? "  catalog unavailable — using billed cost for prices" : "  catalog: \(catalog.count) decision models")
        }
        let doc = BenchExport.document(suite: suite, runs: runs, catalog: catalog)
        let url = o["out"].map { URL(fileURLWithPath: $0) } ?? BenchExport.defaultOutputURL()
        try BenchExport.write(doc, to: url, pretty: o.flags.contains("pretty"))
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let players = runs.filter { !$0.results.isEmpty }
        print("Exported \(suite.id) · \(suite.decisions.count) decisions · \(players.count) players "
              + "(\(players.filter { $0.kind == .decisionModel }.count) decision models) → \(url.path) (\(size / 1024) KB)")
        for r in players where r.results.count < suite.decisions.count {
            print("  note: \(r.label) answered \(r.results.count)/\(suite.decisions.count) — re-export when it finishes")
        }
    }

    // MARK: Experiments

    /// Finds a run on the suite by id, label, "model [variant]" or unique substring.
    public static func findRun(_ q: String, in runs: [BenchmarkRun]) throws -> BenchmarkRun {
        if let r = runs.first(where: { $0.id == q || $0.label == q }) { return r }
        let lq = q.lowercased()
        let hits = runs.filter { $0.id.lowercased().contains(lq) || $0.label.lowercased().contains(lq) }
        if hits.count == 1 { return hits[0] }
        // Prefer a single model run over derived runs built from it ("[multi]" → the model run, not "… [multi] τ=2").
        let models = hits.filter { $0.kind == .decisionModel }
        if models.count == 1 { return models[0] }
        // Prefer an exact model match with the default variant ("typesafe/jev-1.13" → its [v2] run).
        if let r = hits.first(where: { $0.model == q && $0.variantId == DecisionVariants.defaultId }) { return r }
        throw BenchError(hits.isEmpty ? "No run matching '\(q)'. Runs: \(runs.map(\.label).joined(separator: ", "))"
                                      : "'\(q)' is ambiguous: \(hits.map(\.label).joined(separator: ", "))")
    }

    /// Suite restricted to decisions with EV spread ≥ `minSpread` · pot (hands keep their ids; bb/100 then
    /// only counts hands whose remaining decisions were all answered).
    static func filtered(_ suite: BenchmarkSuite, minSpread: Double?) -> BenchmarkSuite {
        guard let m = minSpread, m > 0 else { return suite }
        var s = suite
        s.decisions = suite.decisions.filter { $0.evSpreadPot >= m }
        return s
    }

    static func compare(_ o: Options) throws {
        let full = try suite(o)
        let suite = filtered(full, minSpread: o.double("min-spread"))
        let runs = BenchStore.runs(suiteId: full.id).filter { !$0.results.isEmpty }
        guard !runs.isEmpty else { print("No runs on \(full.id)."); return }
        print(compareText(suite: suite, runs: runs, reference: try o["ref"].map { try findRun($0, in: runs) }))
    }

    public static func compareText(suite: BenchmarkSuite, runs: [BenchmarkRun], reference: BenchmarkRun? = nil) -> String {
        let rows = Scoring.leaderboard(suite: suite, runs: runs)
        let byId = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Default reference: the best decision-model run (or the best run).
        let ref = reference ?? rows.first { $0.isDecisionModel }.flatMap { byId[$0.id] } ?? rows.first.flatMap { byId[$0.id] }
        let hands = suite.isHands
        var out: [String] = []
        out.append("Suite \(suite.id) · \(suite.format.title) · \(suite.decisions.count) decisions" + (hands ? " · \(suite.handIds.count) hands" : "")
                   + (ref.map { " · reference: \($0.label)" } ?? ""))
        var w = [40, 9, 6, 12, 14, 8]
        var head = ["Player", "Kind", "n", "GTO score", "EV loss %pot", "Mixed"]
        if hands { w += [14, 7]; head += ["bb/100 lost", "mixed"] }
        w += [9, 16, 16]
        head += ["Cost", "Δscore vs ref", "ΔEV loss %pot"]
        if hands { w += [16]; head += ["Δbb/100"] }
        out.append(row(head, widths: w, rightAlignFrom: 2))
        out.append(String(repeating: "─", count: w.reduce(0, +) + 2 * (w.count - 1)))
        func d(_ x: Scoring.Diff?, _ f: String, _ scale: Double = 1) -> String {
            guard let x, x.n > 0 else { return "–" }
            return String(format: f, x.mean * scale, x.ci * scale) + (x.significant ? "*" : " ")
        }
        for r in rows {
            guard let run = byId[r.id] else { continue }
            let o = r.overall
            var cells = [r.label + (r.isComplete ? "" : " (\(r.answered)/\(r.total))"),
                         r.kind == .decisionModel ? "model" : r.kind == .derived ? (run.derived?.hybrid == true ? "hybrid" : "derived") : "bot",
                         "\(r.answered)",
                         String(format: "%.1f ±%.1f", o.gtoScore, o.gtoScoreCI),
                         String(format: "%.2f%% ±%.2f", o.meanEVLossPot * 100, o.meanEVLossPotCI * 100),
                         o.meanMixedEVLossPot.map { String(format: "%.2f%%", $0 * 100) } ?? "–"]
            if hands {
                cells += [r.perHand.map { String(format: "%.1f ±%.1f", $0.bbPer100, $0.bbPer100CI) } ?? "–",
                          r.perHand?.mixedBbPer100.map { String(format: "%.1f", $0) } ?? "–"]
            }
            cells.append(r.isBaseline ? "–" : String(format: "$%.3f", r.totalCost))
            if let ref, ref.id != run.id {
                let p = Scoring.paired(run, ref, suite: suite)
                cells += [d(p.score, "%+.1f ±%.1f"), d(p.lossPot, "%+.2f%% ±%.2f", 100)]
                if hands { cells.append(d(p.bbPer100, "%+.1f ±%.1f")) }
            } else {
                cells += ["(ref)", "", ""]
            }
            out.append(row(cells, widths: w, rightAlignFrom: 2))
        }
        out.append("")
        out.append("Δ = player − reference, paired over decisions both answered (bb/100: over complete hands); ± = 95% CI; * = CI excludes 0. "
                   + "Higher Δscore is better; lower ΔEV loss / Δbb/100 is better.")
        return out.joined(separator: "\n")
    }

    static func split(_ o: Options) throws {
        let suite = try suite(o)
        let frac = min(0.95, max(0.05, o.double("dev") ?? 0.5))
        let (dev, test) = splitSuite(suite, devFraction: frac, seed: o["seed"].flatMap(UInt64.init) ?? 1)
        for s in [dev, test] {
            let url = try BenchStore.save(s)
            print("Saved \(s.id) · \(s.decisions.count) decisions" + (s.isHands ? " · \(s.handIds.count) hands" : "") + " → \(url.path)")
        }
    }

    /// Splits by hand (hands suites) or by generating solve (spots), deterministically for a seed.
    public static func splitSuite(_ suite: BenchmarkSuite, devFraction: Double, seed: UInt64) -> (BenchmarkSuite, BenchmarkSuite) {
        let groups = suite.isHands ? suite.handIds : Array(Set(suite.decisions.map { "spot\($0.spotIndex)" })).sorted()
        var rng = SeededRNG(seed: seed, stream: 0x5917)
        var shuffled = groups
        shuffled.shuffle(using: &rng)
        let devSet = Set(shuffled.prefix(Int((Double(groups.count) * devFraction).rounded())))
        func key(_ d: Decision) -> String { suite.isHands ? (d.handId ?? d.id) : "spot\(d.spotIndex)" }
        func make(_ tag: String, _ keep: (Decision) -> Bool) -> BenchmarkSuite {
            var s = suite
            s.id = "\(suite.id)-\(tag)"
            s.name = "\(suite.name) · \(tag)"
            s.decisions = suite.decisions.filter(keep)
            return s
        }
        return (make("dev") { devSet.contains(key($0)) }, make("test") { !devSet.contains(key($0)) })
    }

    static func synth(_ args: [String], _ o: Options) throws {
        let methods: Set<String> = ["ensemble", "ens", "temper", "sharpen", "guardrail", "guard"]
        let method = args.first { methods.contains($0) } ?? ""
        let suite = try suite(o)
        let runs = BenchStore.runs(suiteId: suite.id).filter { !$0.results.isEmpty }
        var made: [BenchmarkRun] = []
        switch method {
        case "ensemble", "ens":
            let members = try o.list("runs").map { try findRun($0, in: runs) }
            let weights = o["weights"].map { $0.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
            made.append(try Synth.ensemble(members, weights: weights, suite: suite, name: o["name"]))
        case "temper", "sharpen":
            guard let q = o["run"] else { throw BenchError("--run is required") }
            let src = try findRun(q, in: runs)
            let taus = (o["tau"] ?? "2").split(separator: ",").compactMap { t -> Double? in
                let x = t.trimmingCharacters(in: .whitespaces).lowercased()
                return x == "inf" ? .infinity : Double(x)
            }
            guard !taus.isEmpty, taus.allSatisfy({ $0 > 0 }) else { throw BenchError("--tau must be positive numbers or inf") }
            made += taus.map { Synth.temper(src, tau: $0, suite: suite) }
        case "guardrail", "guard":
            guard let q = o["run"] else { throw BenchError("--run is required") }
            let src = try findRun(q, in: runs)
            let narrowed = (o["equity"] ?? "narrowed") != "preflop"
            let (run, fired) = Synth.guardrail(src, margin: o.double("margin") ?? 0.05, narrowed: narrowed, suite: suite)
            print("  guard changed \(fired) argmax fold(s) to call")
            made.append(run)
        default:
            throw BenchError("synth needs a method: ensemble, temper or guardrail (see `eqbench bench help`)")
        }
        for r in made {
            try BenchStore.save(r)
            print("Saved derived run \(r.label) (\(r.results.count) answers) → \(r.id)")
        }
        let all = BenchStore.runs(suiteId: suite.id).filter { !$0.results.isEmpty }
        print("")
        print(compareText(suite: suite, runs: all, reference: made.first.flatMap { m in all.first { $0.id == (m.derived?.sources.first ?? "") } }))
    }

    /// Postflop bb/100 lost per game format for every model/variant (and derived/baseline player), pooling the
    /// hands of all hands suites of that format. CI over hands (normal approximation).
    public static func formatsText(model: String? = nil, variant: String? = nil, suites: [BenchmarkSuite]? = nil,
                                   runs allRuns: [BenchmarkRun]? = nil, publishedOnly: Bool = false) -> String {
        let hs = (suites ?? BenchStore.suites()).filter { $0.isHands && (!publishedOnly || BenchExport.isPublished($0)) }
        guard !hs.isEmpty else { return "No hands/preflop suites yet. Run `eqbench bench generate --mode hands|preflop --format <f>`." }
        let runs = (allRuns ?? BenchStore.runs()).filter { r in
            if let m = model, !r.label.lowercased().contains(m.lowercased()) { return false }
            if let v = variant, r.variantId != v { return false }
            return true
        }
        // Columns: (format, preflop|postflop). Preflop and postflop bb/100 are reported separately; hands shared by a
        // suite and its dev/test splits are counted once per player.
        let pooled = FormatPool.pool(suites: hs, runs: runs)
        let formats = pooled.columns.map(\.column)
        var out = ["bb/100 lost vs GTO by format, preflop (pre) and postflop (post) suites separately (argmax ± 95% CI [n hands]; mixed in parentheses)"]
        out.append("Suites: " + pooled.columns.map { "\($0.column.title) \($0.suiteIds.count)" }.joined(separator: " · "))
        let w = [44] + formats.map { _ in 30 }
        out.append(row(["Player"] + formats.map(\.title), widths: w, rightAlignFrom: 1))
        out.append(String(repeating: "─", count: w.reduce(0, +) + 2 * (w.count - 1)))
        func overall(_ l: String) -> Double {
            let cs = pooled.cells[l]!.values
            let n = cs.reduce(0) { $0 + $1.n }
            return n == 0 ? 0 : cs.reduce(0) { $0 + $1.bbPer100 * Double($1.n) } / Double(n)
        }
        let labels = pooled.cells.keys.sorted { overall($0) < overall($1) }
        for l in labels {
            let cells = formats.map { f -> String in
                guard let c = pooled.cells[l]?[f], c.n > 0 else { return "–" }
                return String(format: "%.1f ±%.1f [%d]", c.bbPer100, c.bbPer100CI, c.n) + (c.mixedBbPer100.map { String(format: " (%.1f)", $0) } ?? "")
            }
            out.append(row([l] + cells, widths: w, rightAlignFrom: 1))
        }
        out.append("")
        out.append("bb/100 = 100 × mean over hands of Σ EV loss / 2 (the player plays both seats). Chip EV; ICM not modelled. A full-hand "
                   + "figure is roughly pre + post (different hand samples). "
                   + "Only completely answered hands count." + (publishedOnly ? " Published suites only (as on the website)." : ""))
        return out.joined(separator: "\n")
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
        let hands = suite.isHands
        var w = [3, 40, 12, 15, 8, 6, 7, 8, 8, 13, 9, 7, 8, 9]
        var head = ["#", "Player", "GTO score", "EV loss %pot", "bb/dec", "Best", "GTO-ok", "Blunder", "Invalid",
                    "Mixed %pot", "TV dist", "P(best)", "Latency", "Cost"]
        if hands {
            w.insert(contentsOf: [16, 9], at: 5)
            head.insert(contentsOf: ["bb/100 lost", "mixed"], at: 5)
        }
        out.append(row(head, widths: w, rightAlignFrom: 2))
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
                var cells = [
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
                    r.isDecisionModel ? String(format: "%.1fs", r.meanLatency) : "–",
                    r.isBaseline ? "–" : String(format: "$%.3f", r.totalCost),
                ]
                if hands {
                    let h = r.perHand
                    cells.insert(contentsOf: [h.map { String(format: "%.1f ±%.1f", $0.bbPer100, $0.bbPer100CI) } ?? "–",
                                              h?.mixedBbPer100.map { String(format: "%.1f", $0) } ?? "–"], at: 5)
                }
                out.append(row(cells, widths: w, rightAlignFrom: 2))
            }
        }
        // Breakdowns.
        let streets = Street.allCases.filter { s in rows.contains { $0.byStreet[s.rawValue] != nil } }
        let types = DecisionType.allCases
        let bw = [40] + Array(repeating: 18, count: streets.count + types.count)
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
        if hands {
            out.append("bb/100 lost (hands suite) = 100 × mean over hands of (Σ EV loss of all decisions in the hand) / 2: the player answers "
                       + "both seats, so this is bb lost per 100 hands played in one seat; ± = 95% CI clustered by hand; mixed uses Σ p·loss. "
                       + "One-step deviations along GTO-sampled lines (GTO continues after each decision).")
        }
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
    private var startDone = 0
    private var startCost = 0.0
    private var started = false

    private let perPlayer: Int

    init(names: [String], perPlayer: Int) {
        self.names = names
        self.perPlayer = perPlayer
    }

    func update(_ p: RunProgress) {
        lock.lock()
        defer { lock.unlock() }
        state[p.runId] = p
        guard state.count == names.count else { return }
        if !started {
            started = true
            startDone = state.values.reduce(0) { $0 + min($1.done, perPlayer) }
            startCost = state.values.reduce(0) { $0 + $1.cost }
        }
        guard Date().timeIntervalSince(lastPrint) > 0.2 || p.done >= perPlayer else { return }
        lastPrint = Date()
        let done = state.values.reduce(0) { $0 + min($1.done, perPlayer) }
        let total = perPlayer * names.count
        let cost = state.values.reduce(0) { $0 + $1.cost }
        let invalid = state.values.reduce(0) { $0 + $1.invalid }
        // Projected total from the running cost per answered decision (this session's answers only).
        let newDone = state.values.reduce(0) { $0 + min($1.done, perPlayer) } - startDone
        let projected = newDone > 0 ? cost - startCost + (cost - startCost) / Double(newDone) * Double(total - done) : nil
        let proj = projected.map { String(format: " (projected $%.4f)", $0) } ?? ""
        let line = String(format: "\r  answered %4d/%-4d · invalid %d · cost $%.4f", done, total, invalid, cost) + proj + "   "
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        print("")
        for n in names {
            guard let p = state[n], let e = p.lastError else { continue }
            print("  \(p.label): \(p.invalid) invalid · last error: \(e)")
        }
    }
}
