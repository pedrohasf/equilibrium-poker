import Foundation

/// `eqbench arena export`: arena results for the static website (`web/data/arena.json`).
///
/// Every saved match with at least `minHands` hands is included (self-play excluded). Bot-vs-bot matches are
/// flagged `reference`. `pairs` pools all matches of the same (player, opponent) — bb/100 and CIs come from
/// `MatchStats.units`/`rate` over the pooled duplicate units (exactly what `arena show` prints for a single
/// match), tendencies (VPIP, PFR, AF, …) from `MatchStats.player` over the pooled hands. `leaderboard` is
/// `Leaderboard.compute` over the included matches. No raw model responses are written.
public enum ArenaExport {
    public static let schemaVersion = 1
    public static let defaultMinHands = 100

    static func r(_ x: Double?, _ places: Int = 2) -> Any {
        guard let x, x.isFinite else { return NSNull() }
        let m = pow(10, Double(places))
        return (x * m).rounded() / m
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    static func playerObj(_ s: PlayerSpec) -> [String: Any] {
        ["id": s.id, "kind": s.kind.rawValue, "model": s.model, "mode": s.isDecisionModel ? s.mode.rawValue : NSNull(), "name": s.displayName]
    }

    static func stats(_ p: PlayerSummary) -> [String: Any] {
        ["vpip": r(p.vpip, 4), "pfr": r(p.pfr, 4), "threeBet": r(p.threeBet, 4), "af": r(p.aggression, 3), "wtsd": r(p.wtsd, 4),
         "wsd": r(p.wsd, 4), "cbet": r(p.cbet, 4), "foldToCbet": r(p.foldToCbet, 4), "decisions": p.decisions,
         "invalid": p.invalidActions, "errors": p.errors, "cost": r(p.cost, 5), "latency": r(p.avgLatency, 3),
         "promptTokens": p.promptTokens]
    }

    /// Matches that qualify for the site.
    public static func included(_ matches: [MatchRecord], minHands: Int = defaultMinHands) -> [MatchRecord] {
        matches.filter { $0.players.count == 2 && $0.players[0].id != $0.players[1].id && $0.hands.count >= minHands }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Hands of `m` re-indexed so that `player` is player 0 (A).
    static func asPlayerA(_ m: MatchRecord, player: Int) -> [HandRecord] {
        guard player == 1 else { return m.hands }
        return m.hands.map { h in var c = h; c.seatPlayers = h.seatPlayers.map { 1 - $0 }; return c }
    }

    public static func document(matches all: [MatchRecord], minHands: Int = defaultMinHands, generatedAt: Date = Date()) -> [String: Any] {
        let ms = included(all, minHands: minHands)
        var specs: [String: PlayerSpec] = [:]
        struct Acc { var matches: [String] = []; var units: [ResultUnit] = []; var hands: [HandRecord] = []; var duplicate = true }
        var acc: [String: Acc] = [:]          // "player|opponent"
        var matchObjs: [[String: Any]] = []
        for m in ms {
            let s = m.summary ?? MatchStats.summarize(m)
            let reference = !m.players[0].isDecisionModel && !m.players[1].isDecisionModel
            for p in 0..<2 {
                specs[m.players[p].id] = m.players[p]
                let key = "\(m.players[p].id)|\(m.players[1 - p].id)"
                var a = acc[key] ?? Acc()
                a.matches.append(m.id)
                a.units += MatchStats.units(m.hands, player: p, duplicate: m.config.duplicate)
                a.hands += asPlayerA(m, player: p)
                a.duplicate = a.duplicate && m.config.duplicate
                acc[key] = a
            }
            matchObjs.append([
                "id": m.id, "createdAt": iso(m.createdAt), "status": m.status.rawValue, "reference": reference,
                "a": m.players[0].id, "b": m.players[1].id, "hands": s.hands, "units": s.units,
                "deals": m.config.deals, "duplicate": m.config.duplicate, "stackBB": r(m.config.stackBB, 1),
                "opponentStats": m.config.opponentStats, "seed": String(m.config.seed),
                "players": s.players.map { p -> [String: Any] in
                    ["id": p.id, "bb100": r(p.bb100), "ci95": r(p.ci95), "evBB100": r(p.evBB100), "evCI95": r(p.evCI95),
                     "netBB": r(p.netBB)].merging(stats(p)) { a, _ in a }
                },
            ])
        }
        let pairs: [[String: Any]] = acc.keys.sorted().map { key in
            let a = acc[key]!
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            let spec = specs[parts[0]]!, opp = specs[parts[1]]!
            let rate = MatchStats.rate(a.units)
            let st = MatchStats.player(a.hands, player: 0, spec: spec, duplicate: a.duplicate)
            return ["player": parts[0], "opponent": parts[1], "reference": !spec.isDecisionModel && !opp.isDecisionModel,
                    "matches": a.matches, "hands": a.hands.count, "units": a.units.count,
                    "bb100": r(rate.bb100), "ci95": r(rate.ci95), "evBB100": r(rate.evBB100), "evCI95": r(rate.evCI95),
                    "netBB": r(a.units.reduce(0) { $0 + $1.net })].merging(stats(st)) { x, _ in x }
        }
        let board: [[String: Any]] = Leaderboard.compute(ms).map { e in
            ["id": e.id, "rating": r(e.rating, 0), "matches": e.matches, "hands": e.hands, "units": e.units, "bb100": r(e.bb100),
             "ci95": r(e.ci95), "evBB100": r(e.evBB100), "evCI95": r(e.evCI95), "wins": e.wins, "losses": e.losses, "ties": e.ties,
             "cost": r(e.cost, 5)]
        }
        return [
            "schema": schemaVersion,
            "generatedAt": iso(generatedAt),
            "generator": "Equilibrium · eqbench arena export",
            "minHands": minHands,
            "excluded": all.count - ms.count,
            "bots": BotKind.allCases.map { ["id": "bot:\($0.rawValue)", "title": $0.title, "summary": $0.summary] },
            "players": specs.keys.sorted().map { playerObj(specs[$0]!) },
            "pairs": pairs,
            "matches": matchObjs,
            "leaderboard": board,
        ]
    }

    /// `<repo>/web/data/arena.json` when run inside the repo, otherwise `./web/data/arena.json`.
    public static func defaultOutputURL() -> URL {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("app/Package.swift").path) {
                return dir.appendingPathComponent("web/data/arena.json")
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("web/data/arena.json")
    }

    public static func write(_ doc: [String: Any], to url: URL, pretty: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { opts.insert(.prettyPrinted) }
        try JSONSerialization.data(withJSONObject: doc, options: opts).write(to: url, options: .atomic)
    }
}
