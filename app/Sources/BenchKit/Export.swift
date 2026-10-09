import Foundation
import OpenRouterKit
import SolverKit

/// Exports one suite and every run on it to a single compact JSON document for the static
/// results website (`web/`). Summaries are computed with `Scoring`, so the site shows exactly
/// what `eqbench bench report` prints. No secrets and no raw model responses are written.
public enum BenchExport {
    public static let schemaVersion = 1

    /// Optional live catalog info (display name, input price) keyed by model id.
    public struct CatalogEntry: Sendable {
        public var name: String
        public var promptPricePerM: Double?
        public init(name: String, promptPricePerM: Double?) {
            self.name = name
            self.promptPricePerM = promptPricePerM
        }
    }

    /// Friendly names for the decision models we know about (used before the catalog name).
    static let knownNames: [String: String] = [
        "typesafe/jev-1.13": "TypeSafe Jev 1.13",
        "perplexity/pplx-decider-v1.1-27b": "Perplexity Decider v1.1 27B",
        "openai/gpt-6-luna-decisions": "GPT-6 Luna Decisions",
        "liquid/d1": "Liquid d1",
        "cloudflare/clef": "Cloudflare Clef",
        "cloudflare/clef-flash": "Cloudflare Clef Flash",
        "upstage/solar-decide": "Upstage Solar Decide",
        "upstage/solar-decide-flash": "Upstage Solar Decide Flash",
        "inception/mercury-decide": "Inception Mercury Decide",
        "togethercomputer/tev1-4b-experimental": "Together Tev1 4B (exp.)",
        "jaredpalmer/kev-4b": "Kev 4B",
    ]

    static let knownProviders: [String: String] = [
        "typesafe": "TypeSafe", "perplexity": "Perplexity", "openai": "OpenAI", "liquid": "Liquid AI",
        "cloudflare": "Cloudflare", "upstage": "Upstage", "inception": "Inception", "togethercomputer": "Together AI",
        "jaredpalmer": "Jared Palmer",
    ]

    // MARK: Document

    public static func document(suite: BenchmarkSuite, runs allRuns: [BenchmarkRun],
                                catalog: [String: CatalogEntry] = [:], generatedAt: Date = Date(),
                                borrowed: Set<String> = []) -> EJ {
        let runs = allRuns.filter { $0.suiteId == suite.id && !$0.results.isEmpty }
        let rows = Scoring.leaderboard(suite: suite, runs: runs)
        let runById = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Players in leaderboard order; keys are short, unique and URL-safe.
        var usedKeys = Set<String>()
        let players: [(key: String, row: ModelScore, run: BenchmarkRun)] = rows.compactMap { row in
            guard let run = runById[row.id] else { return nil }
            return (playerKey(run, used: &usedKeys), row, run)
        }

        let playerObjs = players.map { p -> EJ in
            let o = player(key: p.key, row: p.row, run: p.run, suite: suite, catalog: catalog)
            guard borrowed.contains(p.run.id), case .o(let kv) = o else { return o }
            return .o(kv + [("borrowedFrom", .s(FormatPool.split(suite.id).root))])
        }

        // Per-decision answers, aligned with `players`.
        let resultMaps = players.map { p in Dictionary(p.run.results.map { ($0.decisionId, $0) }, uniquingKeysWith: { _, b in b }) }
        let decisionObjs: [EJ] = suite.decisions.map { d in
            let answers: [EJ] = players.indices.map { i in
                guard let r = resultMaps[i][d.id] else { return .null }
                return answer(d, r, run: players[i].run)
            }
            return decision(d, answers: answers)
        }

        let p = suite.parameters
        let exps = suite.decisions.map(\.exploitability)
        let scenarioCounts = suite.countByScenario
        let scenarios: [EJ] = (p.scenarios + Scenarios.every).reduce(into: [Scenario]()) { a, s in if !a.contains(where: { $0.id == s.id }) { a.append(s) } }.filter { scenarioCounts[$0.id] != nil }.map { s in
            .o([("id", .s(s.id)), ("name", .s(s.name)), ("summary", .s(s.summary)), ("oop", .s(s.oopName)), ("ip", .s(s.ipName)),
                ("pot", .n(s.pot, 2)), ("stack", .n(s.stack, 2)), ("count", .i(scenarioCounts[s.id] ?? 0))])
        }
        let trees: [String] = p.handsTree.map { [$0.summary] }
            ?? Array(Set((suite.solveRecords ?? []).compactMap(\.tree))).sorted()
        let treeText = trees.isEmpty ? HandsTreeConfig.standard.summary : trees.joined(separator: " | ")
        let betSizes: [EJ] = suite.isHands
            ? trees.map { t in .o([("root", .s("flop")), ("sizes", .s(t)), ("raiseLimit", .i(p.handsTree?.raiseLimit ?? 1))]) }
            : p.streets.sorted().map { st in
                let (_, raiseLimit) = SuiteGenerator.betSizes(root: st)
                let desc = st == .flop ? "standard sizes (one 33% bet, one raise)" : "bets 33% and 75% pot, raise 60%"
                return .o([("root", .s(st.rawValue)), ("sizes", .s(desc)), ("raiseLimit", .i(raiseLimit))])
            }
        let approximations: [EJ] = suite.mode == .preflop ? [
            .s("Heads-up preflop only (blind vs blind; Spin & Go heads-up), solved by the core's preflop CFR: push/fold at ≤ 12bb, min-raise trees at ≤ 30bb, 2.5x opens deeper (limps, one iso size, one 3-bet and 4-bet size, all-in)."),
            .s("Flop terminals of the deeper preflop trees are valued with an equity-realisation model (all-in equity scaled by position and SPR, see core/src/preflop.rs) instead of a postflop solve, so preflop EVs are approximate."),
            .s("Preflop bb/100 is reported separately from postflop (hands) suites; hands do not continue to the flop."),
            .s("No triviality filter: easy folds/raises are kept (see spreadPot). Chip EV only; ICM is not modelled."),
        ] : suite.isHands ? [
            .s("Each solve is a full flop game from the scenario's preflop ranges; hands are dealt from those ranges and played to the end following GTO, recording every decision of both players, so turn and river ranges are correctly narrowed."),
            .s("The flop tree is deliberately lean and depends on stack depth (\(treeText)), so the equilibrium is for that abstraction."),
            .s("Solves stop near \(String(format: "%.2g", p.targetExploitability))% of the flop pot; EV differences below ~0.25% of the pot are treated as ties."),
            .s(suite.format == .cash ? "Cash game, 100bb." : "\(suite.format.title): chip EV only — tournament payouts (ICM) are not modelled."),
            .s(p.minEVSpread > 0 ? "Decisions whose action EVs are within \(BB.pct(p.minEVSpread)) of the pot were skipped." : "No triviality filter: near-trivial decisions are kept (see spreadPot), as in real play."),
            .s("EV loss is measured against a GTO opponent along GTO-sampled lines (one-step deviations), not in a full match."),
        ] : [
            .s("Turn and river subgames start from the scenario's preflop ranges; the synthetic flop/turn line that sets pot and stacks does not narrow them."),
            .s("Bet trees are deliberately lean (two bet sizes, one raise size, limited raises), so the equilibrium is for that abstraction."),
            .s("Solves stop near the target exploitability, so EV differences below ~0.25% of the pot are treated as ties."),
            .s("Spots where every action is within \(BB.pct(p.minEVSpread)) of the pot of each other are skipped as trivial."),
            .s("EV loss is measured against a GTO opponent, not against the leaks of a real one."),
        ]
        let example = suite.decisions.first { $0.facingBet && $0.actions.count >= 3 } ?? suite.decisions.first
        let exampleState: EJ = example.map { d in
            .o([("decision", .s(d.id)), ("approxInputTokens", .i(DecisionStateBuilder.estimatedInputTokens(d))),
                ("body", EJ(DecisionStateBuilder.requestBody(d, model: DecisionRoster.suggested[0])))])
        } ?? .null

        let suiteObj: EJ = .o([
            ("id", .s(suite.id)),
            ("name", .s(suite.name)),
            ("createdAt", .s(iso(suite.createdAt))),
            ("decisions", .i(suite.decisions.count)),
            ("mode", .s(suite.mode.rawValue)),
            ("format", .o([("id", .s(suite.format.rawValue)), ("title", .s(suite.format.title)), ("summary", .s(suite.format.summary))])),
            ("hands", suite.isHands ? .i(suite.handIds.count) : .null),
            ("solves", .i(suite.solves)),
            ("generationSeconds", .n(suite.generationSeconds, 1)),
            ("seed", .s(String(p.seed))),
            ("streets", .o(Street.allCases.compactMap { s in suite.countByStreet[s].map { (s.rawValue, EJ.i($0)) } })),
            ("types", .o(DecisionType.allCases.map { t in (t.rawValue, EJ.i(suite.decisions.filter { $0.decisionType == t }.count)) })),
            ("scenarios", .a(scenarios)),
            ("solver", .o([
                ("algorithm", .s("Discounted CFR (α = 1.5, β = 0.5, γ = 3), alternating updates, exact best-response exploitability")),
                ("rootStreets", .a(p.streets.sorted().map { .s($0.rawValue) })),
                ("betSizes", .a(betSizes)),
                ("allinThreshold", .n(0.67, 2)),
                ("targetExploitabilityPctPot", .n(p.targetExploitability, 3)),
                ("maxIterations", .i(p.maxIterations)),
                ("meanExploitabilityPctPot", .n(exps.isEmpty ? 0 : exps.reduce(0, +) / Double(exps.count), 3)),
                ("maxExploitabilityPctPot", .n(exps.max() ?? 0, 3)),
                ("minEVSpreadPot", .n(p.minEVSpread, 3)),
                ("decisionsPerSolve", .i(p.decisionsPerSolve)),
                ("handsPerSolve", p.handsPerSolve.map { .i($0) } ?? .null),
                ("solveSeconds", .opt(suite.solveRecords.map { r in r.map(\.solveSeconds).reduce(0, +) / Double(max(1, r.count)) }, 1)),
                ("solveRecords", suite.solveRecords.map { recs in .a(recs.map { r in
                    .o([("scenario", .s(r.scenarioId)), ("board", .s(r.board)), ("spr", .opt(r.spr, 2)), ("expl", .n(r.exploitability, 3)), ("it", .i(r.iterations)),
                        ("solveS", .n(r.solveSeconds, 1)), ("sampleS", .n(r.sampleSeconds, 1)), ("hands", .i(r.hands)), ("decisions", .i(r.decisions))])
                }) } ?? .null),
            ])),
            ("approximations", .a(approximations)),
            ("scoring", .o([
                ("bestTolerancePot", .n(Scoring.bestTolerance, 4)),
                ("approvedFrequency", .n(Scoring.approvedFrequency, 2)),
                ("blunderThresholdPot", .n(Scoring.blunderThreshold, 2)),
            ])),
            ("stateVersion", .i(DecisionStateBuilder.version)),
            ("variants", .a(DecisionVariants.all.map { v in .o([("id", .s(v.id)), ("summary", .s(v.summary))]) })),
            ("exampleState", exampleState),
        ])

        return .o([
            ("schema", .i(schemaVersion)),
            ("generatedAt", .s(iso(generatedAt))),
            ("generator", .s("Equilibrium · eqbench bench export")),
            ("suite", suiteObj),
            ("players", .a(playerObjs)),
            ("decisions", .a(decisionObjs)),
        ])
    }

    // MARK: Pieces

    /// Short, unique, URL-safe key for a run ("jev-1.13", "gpt-6-luna-decisions-eq", "callingstation").
    static func playerKey(_ run: BenchmarkRun, used: inout Set<String>) -> String {
        var base = Baseline(id: run.model).map(\.rawValue)
            ?? String(run.model.split(separator: "/").last ?? Substring(run.model))
        if run.kind == .decisionModel, let v = run.variantId, v != DecisionVariants.defaultId { base += "-\(v)" }
        if run.kind == .derived { base = String(run.model.dropFirst("derived:".count)) }
        base = base.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "-" }.reduce(into: "") { $0.append($1) }
        var key = base
        var n = 2
        while used.contains(key) { key = "\(base)-\(n)"; n += 1 }
        used.insert(key)
        return key
    }

    /// Friendly model name without variant ("GPT-6 Luna Decisions"), for decision models, baselines and derived runs.
    public static func modelName(_ model: String, catalog: [String: CatalogEntry] = [:]) -> String {
        if let b = Baseline(id: model) { return b.displayName }
        if let k = knownNames[model] { return k }
        if let c = catalog[model]?.name { return c.contains(": ") ? String(c.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces) : c }
        return model
    }

    /// Display name of a run: model name plus " [variant]" for non-default variants; derived runs keep their own name.
    public static func displayName(_ run: BenchmarkRun, catalog: [String: CatalogEntry] = [:]) -> String {
        if run.kind == .derived { return run.displayName }
        var name = modelName(run.model, catalog: catalog)
        if run.kind == .decisionModel, let v = run.variantId, v != DecisionVariants.defaultId { name += " [\(v)]" }
        return name
    }

    static func bucket(_ b: ScoreBucket) -> EJ {
        var f: [(String, EJ)] = [
            ("n", .i(b.n)),
            ("score", .n(b.gtoScore, 2)), ("scoreCI", .n(b.gtoScoreCI, 2)),
            ("lossPot", .n(b.meanEVLossPot, 5)), ("lossPotCI", .n(b.meanEVLossPotCI, 5)),
            ("lossBB", .n(b.meanEVLoss, 4)), ("lossBBCI", .n(b.meanEVLossCI, 4)),
            ("best", .n(b.accuracy, 4)), ("approved", .n(b.approvedRate, 4)),
            ("blunder", .n(b.blunderRate, 4)), ("invalid", .n(b.invalidRate, 4)),
        ]
        if b.distributionN > 0 {
            f += [("distN", .i(b.distributionN)),
                  ("mixedPot", .opt(b.meanMixedEVLossPot, 5)), ("mixedPotCI", .opt(b.meanMixedEVLossPotCI, 5)),
                  ("mixedBB", .opt(b.meanMixedEVLoss, 4)),
                  ("tv", .opt(b.meanTVDistance, 4)), ("tvCI", .opt(b.meanTVDistanceCI, 4)),
                  ("pBest", .opt(b.meanBestActionProbability, 4)), ("confidence", .opt(b.meanConfidence, 4))]
        }
        return .o(f)
    }

    static func player(key: String, row: ModelScore, run: BenchmarkRun, suite: BenchmarkSuite,
                       catalog: [String: CatalogEntry]) -> EJ {
        let ids = Set(suite.decisions.map(\.id))
        let results = run.results.filter { ids.contains($0.decisionId) }
        let baseline = Baseline(id: run.model)
        let providerSlug = String(run.model.split(separator: "/").first ?? "")
        // Provider and resolved model version as reported by OpenRouter in the responses.
        var servedBy: String?, resolved: String?
        for r in results.reversed() {
            guard let raw = r.rawResponse, raw.hasPrefix("{"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { continue }
            servedBy = servedBy ?? (obj["provider"] as? String)
            resolved = resolved ?? (obj["model"] as? String)
            if servedBy != nil && resolved != nil { break }
        }
        let name = displayName(run, catalog: catalog)

        let lat = results.filter(\.isValid).map(\.latency).filter { $0 > 0 }.sorted()
        func q(_ p: Double) -> Double { lat.isEmpty ? 0 : lat[min(lat.count - 1, Int((Double(lat.count - 1) * p).rounded()))] }
        let answered = max(1, row.answered)
        let prompt = results.reduce(0) { $0 + $1.promptTokens }
        // Effective input price from billed cost (decision models bill input tokens only).
        let effectivePrice = prompt > 0 && row.totalCost > 0 ? row.totalCost / Double(prompt) * 1_000_000 : nil

        var f: [(String, EJ)] = [
            ("key", .s(key)),
            ("model", .s(run.model)),
            ("name", .s(name)),
            ("kind", .s(run.kind.rawValue)),
        ]
        if let b = baseline {
            f += [("baseline", .s(b.rawValue)), ("summary", .s(b.summary))]
        } else if run.kind == .derived {
            f += [("summary", .s(run.derived?.description ?? ""))]
        } else {
            f += [("provider", .s(knownProviders[providerSlug] ?? servedBy ?? providerSlug))]
            if let servedBy { f.append(("servedBy", .s(servedBy))) }
            if let resolved { f.append(("resolvedModel", .s(resolved))) }
            f += [("url", .s("https://openrouter.ai/\(run.model)"))]
        }
        if let v = run.variantId, run.kind == .decisionModel {
            f += [("variant", .s(v)), ("label", .s(run.label))]
        }
        if let dv = run.derived {
            f += [("derived", .o([("method", .s(dv.method)), ("sources", .a(dv.sources.map { .s($0) })), ("description", .s(dv.description)),
                                  ("hybrid", .b(dv.hybrid))]))]
        }
        if let h = row.perHand {
            f += [("perHand", .o([("hands", .i(h.hands)), ("bbPer100", .n(h.bbPer100, 2)), ("bbPer100CI", .n(h.bbPer100CI, 2)),
                                  ("mixedBbPer100", .opt(h.mixedBbPer100, 2)), ("mixedBbPer100CI", .opt(h.mixedBbPer100CI, 2)),
                                  ("bySeat", .o(h.bySeat.keys.sorted().map { ($0, EJ.n(h.bySeat[$0]!, 2)) }))]))]
        }
        f += [
            ("answered", .i(row.answered)),
            ("total", .i(row.total)),
            ("complete", .b(row.isComplete)),
            ("overall", bucket(row.overall)),
            ("byStreet", .o(Street.allCases.compactMap { s in row.byStreet[s.rawValue].map { (s.rawValue, bucket($0)) } })),
            ("byType", .o(DecisionType.allCases.compactMap { t in row.byType[t.rawValue].map { (t.rawValue, bucket($0)) } })),
        ]
        if run.kind == .derived {
            f += [("cost", .o([("total", .n(row.totalCost, 6)), ("per1k", .n(row.totalCost / Double(answered) * 1000, 4))]))]
        }
        if run.kind == .decisionModel {
            f += [
                ("latency", .o([("mean", .n(row.meanLatency, 3)), ("median", .n(q(0.5), 3)), ("p90", .n(q(0.9), 3))])),
                ("cost", .o([("total", .n(row.totalCost, 6)), ("per1k", .n(row.totalCost / Double(answered) * 1000, 4))])),
                ("tokens", .o([("prompt", .i(prompt)), ("completion", .i(row.completionTokens)),
                               ("promptPerDecision", .i(Int((Double(prompt) / Double(answered)).rounded())))])),
                ("inputPricePerM", .opt(catalog[run.model]?.promptPricePerM ?? effectivePrice, 4)),
                ("inputPriceSource", .s(catalog[run.model]?.promptPricePerM != nil ? "catalog" : effectivePrice != nil ? "billed" : "unknown")),
            ]
            if let v = run.stateVersion { f.append(("stateVersion", .i(v))) }
        }
        f += [("updatedAt", .s(iso(run.updatedAt)))]
        return .o(f)
    }

    /// `[choice (-1 = invalid), lossPot, probabilities|null, confidence|null, mixedLossPot|null, latency|null]`.
    static func answer(_ d: Decision, _ r: DecisionResult, run: BenchmarkRun) -> EJ {
        let s = Scoring.score(d, result: r, run: run)
        let probs: EJ = r.actionProbabilities.map { ps in .a(ps.map { .n($0, 3) }) } ?? .null
        return .a([.i(s.choice ?? -1), .n(s.evLossPot, 4), probs, .opt(r.confidence, 3), .opt(s.mixedEVLossPot, 4),
                   run.kind == .decisionModel ? .n(r.latency, 2) : .null])
    }

    static func decision(_ d: Decision, answers: [EJ]) -> EJ {
        // Street-by-street history (cards dealt, pot at start, actions with seat).
        var streets: [EJ] = []
        for street in Street.historyStreets(upTo: d.street) {
            let cards: [String]
            switch street {
            case .preflop: cards = []
            case .flop: cards = Array(d.board.prefix(3))
            case .turn: cards = d.board.count > 3 ? [d.board[3]] : []
            case .river: cards = d.board.count > 4 ? [d.board[4]] : []
            }
            let entries = d.history.filter { $0.street == street && $0.action != nil }
            let potStart = street <= .flop ? d.flopPot
                : (d.history.first { $0.street == street }?.potBefore ?? entries.first?.potBefore ?? d.pot)
            let acts: [EJ] = entries.map { e in
                .o([("seat", .i(e.seat ?? 0)), ("t", .s(e.text(names: d.positions))), ("k", .s(e.action?.kind.rawValue ?? "")),
                    ("syn", .b(e.synthetic))])
            }
            streets.append(.o([("street", .s(street.rawValue)), ("cards", .a(cards.map { .s($0) })),
                               ("pot", .n(potStart, 2)), ("acts", .a(acts))]))
        }
        let acts: [EJ] = d.actions.map { a in
            .o([("l", .s(a.detailedLabel)), ("s", .s(a.shortLabel)), ("k", .s(a.kind.rawValue)), ("amt", .n(a.amount, 2))])
        }
        let hero = Card.parseList(d.heroCards)?.map(\.description) ?? [d.heroCards]
        let villain = Card.parseList(d.villainCards)?.map(\.description) ?? [d.villainCards]
        return .o([
            ("id", .s(d.id)),
            ("street", .s(d.street.rawValue)),
            ("type", .s(d.decisionType.rawValue)),
            ("scenario", .s(d.scenarioId)),
            ("preflop", .s(d.preflopSummary)),
            ("positions", .a(d.positions.map { .s($0) })),
            ("heroSeat", .i(d.heroSeat)),
            ("hero", .a(hero.map { .s($0) })),
            ("villain", .a(villain.map { .s($0) })),
            ("board", .a(d.board.map { .s($0) })),
            ("pot", .n(d.pot, 2)),
            ("stacks", .a(d.stacks.map { .n($0, 2) })),
            ("toCall", .n(d.toCall, 2)),
            ("equity", .n(d.equity, 3)),
            ("expl", .n(d.exploitability, 3)),
            ("history", .a(streets)),
            ("actions", .a(acts)),
            ("gto", .a(d.strategy.map { .n($0, 3) })),
            ("ev", .a(d.actionEVs.map { .n($0, 3) })),
            ("best", .i(d.bestAction)),
            ("spreadPot", .n(d.evSpread / max(d.pot, 1e-9), 4)),
            ("hand", d.handId.map { .s($0) } ?? .null),
            ("handSeq", d.handSeq.map { .i($0) } ?? .null),
            ("answers", .a(answers)),
        ])
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    // MARK: Output location

    /// `<repo>/web/data/results.json` when run inside the repo (a parent holds `app/Package.swift`),
    /// otherwise `./web/data/results.json`.
    public static func defaultOutputURL() -> URL {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("app/Package.swift").path) {
                return dir.appendingPathComponent("web/data/results.json")
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("web/data/results.json")
    }

    public static func write(_ doc: EJ, to url: URL, pretty: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(doc.text(pretty: pretty).utf8).write(to: url, options: .atomic)
    }
}

// MARK: - Ordered, rounded JSON

/// Tiny JSON tree with ordered keys and per-number rounding, so exports stay small and diff-friendly.
public indirect enum EJ: Sendable {
    case s(String)
    /// Number rounded to `places` decimals.
    case n(Double, Int)
    case i(Int)
    case b(Bool)
    case a([EJ])
    case o([(String, EJ)])
    case null

    static func opt(_ x: Double?, _ places: Int) -> EJ { x.map { .n($0, places) } ?? .null }

    init(_ v: JSONValue) {
        switch v {
        case .string(let s): self = .s(s)
        case .number(let x): self = x == x.rounded() && abs(x) < 1e15 ? .i(Int(x)) : .n(x, 4)
        case .bool(let b): self = .b(b)
        case .array(let a): self = .a(a.map(EJ.init))
        case .object(let o): self = .o(o.keys.sorted().map { ($0, EJ(o[$0]!)) })
        case .null: self = .null
        }
    }

    public func text(pretty: Bool = false) -> String {
        var out = ""
        write(&out, pretty: pretty, indent: 0)
        return out + (pretty ? "\n" : "")
    }

    static func number(_ x: Double, _ places: Int) -> String {
        guard x.isFinite else { return "null" }
        var s = String(format: "%.\(max(0, places))f", x)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        if s == "-0" { s = "0" }
        return s
    }

    static func quote(_ s: String) -> String {
        var o = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            default:
                if u.value < 0x20 { o += String(format: "\\u%04x", u.value) } else { o.unicodeScalars.append(u) }
            }
        }
        return o + "\""
    }

    func write(_ out: inout String, pretty: Bool, indent: Int) {
        let nl = pretty ? "\n" + String(repeating: "  ", count: indent + 1) : ""
        let end = pretty ? "\n" + String(repeating: "  ", count: indent) : ""
        switch self {
        case .s(let s): out += EJ.quote(s)
        case .n(let x, let p): out += EJ.number(x, p)
        case .i(let x): out += String(x)
        case .b(let b): out += b ? "true" : "false"
        case .null: out += "null"
        case .a(let xs):
            // Arrays of scalars stay on one line even when pretty.
            let scalar = xs.allSatisfy { if case .a = $0 { return false }; if case .o = $0 { return false }; return true }
            out += "["
            for (k, x) in xs.enumerated() {
                if k > 0 { out += "," }
                if !scalar { out += nl }
                x.write(&out, pretty: pretty, indent: indent + 1)
            }
            out += (scalar || xs.isEmpty ? "" : end) + "]"
        case .o(let kv):
            out += "{"
            for (k, (key, v)) in kv.enumerated() {
                if k > 0 { out += "," }
                out += nl + EJ.quote(key) + (pretty ? ": " : ":")
                v.write(&out, pretty: pretty, indent: indent + 1)
            }
            out += (kv.isEmpty ? "" : end) + "}"
        }
    }
}
