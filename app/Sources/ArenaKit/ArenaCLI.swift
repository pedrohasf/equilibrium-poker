import Foundation
import OpenRouterKit

/// `eqbench arena ...` subcommands.
public enum ArenaCLI {
    public static let usage = """
    eqbench arena — heads-up NLHE matches between System One decision models and bots (duplicate format).

    USAGE:
      eqbench arena match --a <player> --b <player> [--deals 50] [--seed 1] [--concurrency 4]
                          [--stats] [--single] [--verbose] [--no-save]
      eqbench arena list                       Saved matches
      eqbench arena show <match-id> [hand#] [--probs]
                                               Summary, or a PokerStars-style hand history
      eqbench arena leaderboard                Ratings across all saved matches
      eqbench arena bots                       Built-in bots
      eqbench arena decision-models            Live catalog of System One decision models

    PLAYERS:
      bot:tag, bot:station, bot:maniac, bot:random, or an OpenRouter System One decision model:
      typesafe/jev-1.13 (or dm:typesafe/jev-1.13) plays the model's top choice (argmax);
      typesafe/jev-1.13~mix samples from its probabilities (seeded). Model ids are checked
      against the live catalog (`eqbench arena decision-models`).

    OPTIONS:
      --deals N        distinct deals; each is played twice with seats swapped (2N hands)
      --single         play each deal once (no duplicate), alternating the button
      --stats          include a running opponent-stats summary in decision-model states
      --verbose        print every hand history (with decision-model probabilities) as it finishes
      --probs          (show) include decision-model probabilities / bot rationale; alias --reasoning
    """

    public static func run(_ args: [String]) async throws {
        var rest = Array(args.dropFirst())
        switch args.first {
        case "match": try await match(&rest)
        case "list": list()
        case "show": try show(rest)
        case "leaderboard": leaderboard()
        case "bots": bots()
        case "decision-models", "dm": try await decisionModels()
        default: print(usage)
        }
    }

    // MARK: Argument helpers

    static func option(_ name: String, _ args: inout [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        let v = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return v
    }

    static func flag(_ name: String, _ args: inout [String]) -> Bool {
        guard let i = args.firstIndex(of: name) else { return false }
        args.remove(at: i)
        return true
    }

    static func pad(_ s: String, _ n: Int, right: Bool = false) -> String {
        if s.count >= n { return s }
        let p = String(repeating: " ", count: n - s.count)
        return right ? p + s : s + p
    }

    static func signed(_ x: Double, _ d: Int = 1) -> String { String(format: "%+.\(d)f", abs(x) < 1e-9 ? 0 : x) }
    static func pct(_ x: Double?) -> String { x.map { String(format: "%.0f%%", $0 * 100) } ?? "–" }

    // MARK: match

    static func match(_ args: inout [String]) async throws {
        guard let aText = option("--a", &args), let bText = option("--b", &args) else {
            print(usage)
            return
        }
        guard let a = PlayerSpec.parse(aText) else { throw EngineError("unknown player '\(aText)'") }
        guard let b = PlayerSpec.parse(bText) else { throw EngineError("unknown player '\(bText)'") }
        var config = MatchConfig()
        config.deals = Int(option("--deals", &args) ?? "") ?? 50
        config.seed = UInt64(option("--seed", &args) ?? "") ?? 1
        config.concurrency = Int(option("--concurrency", &args) ?? "") ?? 4
        config.duplicate = !flag("--single", &args)
        config.opponentStats = flag("--stats", &args)
        let verbose = flag("--verbose", &args)
        let save = !flag("--no-save", &args)

        let needsKey = a.usesOpenRouter || b.usesOpenRouter
        let client: OpenRouterClient? = needsKey ? try OpenRouterClient.fromStoredKey(maxConcurrent: max(4, config.concurrency * 2)) : nil
        // Only System One decision models are supported: validate ids against the live catalog.
        if let client {
            let ids = Set(try await client.decisionModels().map(\.id))
            for spec in [a, b] where spec.isDecisionModel && !ids.contains(spec.model) {
                throw EngineError("'\(spec.model)' is not a System One decision model (see `eqbench arena decision-models`)")
            }
        }
        let players = try [a, b].map { try PlayerFactory.make($0, decisions: client, includeMatchSummary: config.opponentStats) }

        let id = MatchRecord.newID()
        print("Match \(id): A = \(a.id)  vs  B = \(b.id)")
        print("\(config.deals) deals × \(config.duplicate ? "2 (duplicate)" : "1") = \(config.totalHands) hands · seed \(config.seed) · concurrency \(config.concurrency)\n")
        let every = max(1, config.totalHands / 20)
        let stub = MatchRecord(id: id, config: config, players: [a, b])
        let started = Date()

        let task = Task {
            await MatchRunner.run(id: id, config: config, specs: [a, b], players: players, save: save, onEvent: { event in
                guard case .handFinished(let hand, let p) = event else { return }
                if verbose {
                    print(HandHistoryFormatter.format(hand, match: stub, includeReasoning: true) + "\n")
                }
                if verbose || p.handsDone % every == 0 || p.handsDone == p.handsTotal {
                    let line = "[\(pad(String(p.handsDone), 4, right: true))/\(p.handsTotal)]  A \(pad(signed(p.net[0]), 8, right: true)) bb"
                        + "  (all-in EV \(pad(signed(p.evNet[0]), 8, right: true)))"
                        + (p.cost[0] + p.cost[1] > 0 ? String(format: "  cost $%.4f", p.cost[0] + p.cost[1]) : "")
                    print(line)
                }
            })
        }
        // Ctrl-C cancels the match; completed hands are still saved.
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nCancelling…\n".utf8))
            task.cancel()
        }
        sigint.resume()
        let record = await task.value
        sigint.cancel()

        print("")
        printSummary(record)
        print(String(format: "\nElapsed %.2fs", Date().timeIntervalSince(started)))
        if save && !record.hands.isEmpty { print("Saved to \(MatchStore.url(for: record.id).path)") }
        if let e = record.error { print("Match \(record.status.rawValue): \(e)") }
    }

    static func printSummary(_ m: MatchRecord) {
        guard let s = m.summary ?? Optional(MatchStats.summarize(m)) else { return }
        let a = s.players[0], b = s.players[1]
        print("Result: \(m.status.rawValue) · \(s.hands) hands · \(s.units) \(m.config.duplicate ? "duplicate pairs" : "units")")
        let w0 = 24, w = 22
        func row(_ label: String, _ x: String, _ y: String) {
            print(pad(label, w0) + pad(x, w, right: true) + pad(y, w, right: true))
        }
        func ci(_ v: Double, _ c: Double?) -> String { signed(v) + (c.map { " ± " + String(format: "%.1f", $0) } ?? "") }
        row("", "A " + a.id, "B " + b.id)
        row("Net (bb)", signed(a.netBB, 2), signed(b.netBB, 2))
        row("bb/100 (95% CI)", ci(a.bb100, a.ci95), ci(b.bb100, b.ci95))
        row("All-in EV bb/100", ci(a.evBB100, a.evCI95), ci(b.evBB100, b.evCI95))
        row("VPIP", pct(a.vpip), pct(b.vpip))
        row("PFR", pct(a.pfr), pct(b.pfr))
        row("3-bet", pct(a.threeBet), pct(b.threeBet))
        row("Aggression factor", a.aggression.map { String(format: "%.2f", $0) } ?? "–", b.aggression.map { String(format: "%.2f", $0) } ?? "–")
        row("WTSD", pct(a.wtsd), pct(b.wtsd))
        row("W$SD", pct(a.wsd), pct(b.wsd))
        row("C-bet", pct(a.cbet), pct(b.cbet))
        row("Fold to c-bet", pct(a.foldToCbet), pct(b.foldToCbet))
        row("Decisions", "\(a.decisions)", "\(b.decisions)")
        row("Invalid actions", "\(a.invalidActions)", "\(b.invalidActions)")
        if a.cost + b.cost > 0 || a.avgLatency != nil || b.avgLatency != nil {
            row("Cost", String(format: "$%.4f", a.cost), String(format: "$%.4f", b.cost))
            row("Avg latency", a.avgLatency.map { String(format: "%.2fs", $0) } ?? "–", b.avgLatency.map { String(format: "%.2fs", $0) } ?? "–")
            row("Input tokens", "\(a.promptTokens)", "\(b.promptTokens)")
        }
    }

    // MARK: list / show

    static func list() {
        let all = MatchStore.all()
        if all.isEmpty { print("No saved matches in \(MatchStore.directory.path)"); return }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        for m in all {
            let s = m.summary ?? MatchStats.summarize(m)
            let a = s.players[0]
            print("\(pad(m.id, 22)) \(df.string(from: m.createdAt))  \(pad(m.players[0].id, 26)) vs \(pad(m.players[1].id, 26)) "
                  + "\(pad(String(s.hands), 5, right: true)) hands  A \(pad(signed(a.bb100), 8, right: true)) bb/100  \(m.status.rawValue)")
        }
    }

    static func show(_ args: [String]) throws {
        var rest = args
        let probsFlag = flag("--probs", &rest)
        let reasoningAlias = flag("--reasoning", &rest)
        let probs = probsFlag || reasoningAlias
        guard let id = rest.first else { print(usage); return }
        let m = try MatchStore.find(id)
        if rest.count > 1, let n = Int(rest[1]) {
            guard let h = m.hands.first(where: { $0.number == n }) else { throw EngineError("hand #\(n) not found (1…\(m.hands.count))") }
            print(HandHistoryFormatter.format(h, match: m, includeReasoning: probs))
            return
        }
        print("Match \(m.id) · \(m.title) · seed \(m.config.seed)")
        printSummary(m)
        print("\nBiggest pots:")
        for h in m.hands.sorted(by: { $0.result.pot > $1.result.pot }).prefix(5) {
            print("  #\(pad(String(h.number), 4)) pot \(pad(Chips.text(h.result.pot), 6, right: true)) bb   A \(signed(h.net(0), 2)) bb")
        }
        print("\nShow a hand with: eqbench arena show \(m.id) <hand#>")
    }

    // MARK: leaderboard / bots

    static func leaderboard() {
        let entries = Leaderboard.compute(MatchStore.all())
        if entries.isEmpty { print("No saved matches yet. Run `eqbench arena match ...` first."); return }
        print(pad("#", 3) + pad("Player", 34) + pad("Rating", 8, right: true) + pad("bb/100", 10, right: true) + pad("± 95%", 8, right: true)
              + pad("EV bb/100", 11, right: true) + pad("W-L-T pairs", 14, right: true) + pad("Hands", 8, right: true) + pad("Matches", 9, right: true))
        for (i, e) in entries.enumerated() {
            print(pad("\(i + 1)", 3) + pad(e.id, 34) + pad(String(format: "%.0f", e.rating), 8, right: true)
                  + pad(signed(e.bb100), 10, right: true) + pad(e.ci95.map { String(format: "%.1f", $0) } ?? "–", 8, right: true)
                  + pad(signed(e.evBB100), 11, right: true) + pad("\(e.wins)-\(e.losses)-\(e.ties)", 14, right: true)
                  + pad("\(e.hands)", 8, right: true) + pad("\(e.matches)", 9, right: true))
        }
        print("\nRating: Bradley–Terry (Elo scale, mean 1500); each match scores the share of big blinds won across duplicate pairs.\nW-L-T counts duplicate pairs. Self-play matches are excluded.")
    }

    static func decisionModels() async throws {
        let client = try OpenRouterClient.fromStoredKey()
        let models = try await client.decisionModels().sorted { $0.id < $1.id }
        if models.isEmpty { print("No decision models in the catalog."); return }
        let suggested = Set(DecisionRoster.suggested)
        print(pad("Model", 46) + pad("Input $/M", 11, right: true) + "  Player spec")
        for m in models {
            let price = m.promptPricePerM.map { String(format: "$%.3f", $0) } ?? "?"
            print(pad(m.id + (suggested.contains(m.id) ? " *" : ""), 46) + pad(price, 11, right: true) + "  dm:\(m.id)[~mix]")
        }
        let missing = DecisionRoster.suggested.filter { id in !models.contains { $0.id == id } }
        print("\n* suggested roster. Decision models bill input tokens only; output is free.")
        if !missing.isEmpty { print("Suggested but not in the live catalog: " + missing.joined(separator: ", ")) }
    }

    static func bots() {
        for b in BotKind.allCases {
            print("\(pad("bot:" + b.rawValue, 14)) \(pad(b.title, 16)) \(b.summary)")
        }
    }
}
