import Foundation
import OpenRouterKit
import SolverKit

// MARK: - Player protocol

/// Everything a player sees when asked for a decision.
public struct DecisionContext: Sendable {
    public var state: HandState
    /// Seat to act (0 = button / small blind, 1 = big blind).
    public var seat: Int
    /// Numbered legal actions (index 0 = option 1).
    public var menu: [MenuOption]
    public var handNumber: Int
    /// Deterministic per-decision seed for randomised players.
    public var rngSeed: UInt64
    /// Optional running summary of the match / opponent tendencies.
    public var matchSummary: String?

    public init(state: HandState, seat: Int, menu: [MenuOption], handNumber: Int, rngSeed: UInt64, matchSummary: String? = nil) {
        self.state = state
        self.seat = seat
        self.menu = menu
        self.handNumber = handNumber
        self.rngSeed = rngSeed
        self.matchSummary = matchSummary
    }

    public var legal: LegalActions? { state.legalActions() }
    public var hole: [Card] { state.hole[seat] }
    public var opponent: Int { 1 - seat }
}

public struct Decision: Sendable {
    public var action: ArenaAction
    public var meta: DecisionMeta?

    public init(_ action: ArenaAction, meta: DecisionMeta? = nil) {
        self.action = action
        self.meta = meta
    }
}

public protocol ArenaPlayer: Sendable {
    var name: String { get }
    func decide(_ ctx: DecisionContext) async throws -> Decision
}

// MARK: - Player specs

public enum BotKind: String, CaseIterable, Codable, Sendable {
    case tag, station, maniac, random

    public var title: String {
        switch self {
        case .tag: return "TAG bot"
        case .station: return "Calling station"
        case .maniac: return "Maniac"
        case .random: return "Random"
        }
    }

    public var summary: String {
        switch self {
        case .tag: return "Tight-aggressive: preflop charts from the range library, postflop equity thresholds vs. a plausible range."
        case .station: return "Never folds, never raises: checks or calls everything."
        case .maniac: return "Bets and raises big at every opportunity, rarely folds."
        case .random: return "Uniformly random among fold / check-call / raise, random size."
        }
    }
}

/// How a decision-model player turns the returned probabilities into an action.
public enum DecisionMode: String, Codable, Sendable, CaseIterable {
    /// Play the model's top choice.
    case argmax
    /// Sample from the returned probabilities (seeded), i.e. play a randomized strategy.
    case mixed

    public var title: String { self == .argmax ? "Argmax" : "Mixed" }
}

/// Serializable description of a participant: a bot or an OpenRouter System One decision model.
///
/// Matches saved by older builds may contain other kinds (e.g. chat models, `"kind": "llm"`); those
/// fail to decode and `MatchStore.all()` skips them.
public struct PlayerSpec: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case bot, decision }

    public var kind: Kind
    /// Bot raw value ("tag") or OpenRouter decision model id ("typesafe/jev-1.13").
    public var model: String
    /// Decision models only (nil = argmax).
    public var decisionMode: DecisionMode?

    public init(kind: Kind, model: String, decisionMode: DecisionMode? = nil) {
        self.kind = kind
        self.model = model
        self.decisionMode = decisionMode
    }

    public static func bot(_ b: BotKind) -> PlayerSpec { PlayerSpec(kind: .bot, model: b.rawValue) }
    public static func decision(_ model: String, mode: DecisionMode = .argmax) -> PlayerSpec {
        PlayerSpec(kind: .decision, model: model, decisionMode: mode)
    }

    public var isDecisionModel: Bool { kind == .decision }
    /// True for anything that calls OpenRouter (needs an API key).
    public var usesOpenRouter: Bool { kind != .bot }
    public var mode: DecisionMode { decisionMode ?? .argmax }

    /// Stable key used by the leaderboard: "bot:tag", "dm:typesafe/jev-1.13", "dm:typesafe/jev-1.13~mix".
    public var id: String {
        switch kind {
        case .bot: return "bot:\(model)"
        case .decision: return "dm:\(model)" + (mode == .mixed ? "~mix" : "")
        }
    }

    public var bot: BotKind? { kind == .bot ? BotKind(rawValue: model) : nil }

    /// Short display name ("TAG bot", "jev-1.13", "jev-1.13 · mixed").
    public var displayName: String {
        if let b = bot { return b.title }
        let base = String(model.split(separator: "/").last ?? Substring(model))
        return base + (mode == .mixed ? " · mixed" : "")
    }

    /// Provider segment ("typesafe") or "bot".
    public var provider: String {
        kind == .bot ? "bot" : String(model.split(separator: "/").first ?? "")
    }

    /// Parses "bot:tag", "tag", "random", or a decision model: "typesafe/jev-1.13", "dm:typesafe/jev-1.13",
    /// "typesafe/jev-1.13~mix". Model ids are not validated here; callers check them against the live catalog.
    public static func parse(_ text: String) -> PlayerSpec? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let lower = t.lowercased()
        let botName = lower.hasPrefix("bot:") ? String(lower.dropFirst(4)) : lower
        let aliases: [String: BotKind] = ["tag": .tag, "station": .station, "calling-station": .station, "callingstation": .station,
                                          "maniac": .maniac, "random": .random]
        if let b = aliases[botName] { return .bot(b) }
        if lower.hasPrefix("bot:") { return nil }

        var body = t
        for prefix in ["dm:", "decision:"] where lower.hasPrefix(prefix) {
            body = String(t.dropFirst(prefix.count))
        }
        var mode = DecisionMode.argmax
        if let r = body.range(of: "~", options: .backwards) {
            switch body[r.upperBound...].lowercased() {
            case "mix", "mixed", "sample": mode = .mixed
            case "argmax", "max", "top": mode = .argmax
            default: return nil
            }
            body = String(body[..<r.lowerBound])
        }
        guard body.contains("/"), !body.contains("@"), !body.contains(" ") else { return nil }
        return .decision(body, mode: mode)
    }
}

public enum PlayerFactory {
    /// Builds a player. Decision models require a decision provider (an OpenRouter client).
    public static func make(_ spec: PlayerSpec, decisions: (any DecisionProvider)?,
                            includeMatchSummary: Bool = false) throws -> any ArenaPlayer {
        switch spec.kind {
        case .bot:
            switch spec.bot {
            case .tag: return TightAggressiveBot()
            case .station: return CallingStation()
            case .maniac: return ManiacBot()
            case .random: return RandomBot()
            case nil: throw EngineError("unknown bot '\(spec.model)'")
            }
        case .decision:
            guard let decisions else { throw EngineError("an OpenRouter API key is required for \(spec.model)") }
            return DecisionModelPlayer(model: spec.model, mode: spec.mode, includeMatchSummary: includeMatchSummary,
                                       client: decisions)
        }
    }
}

// MARK: - Simple bots

public struct CallingStation: ArenaPlayer {
    public init() {}
    public var name: String { "Calling station" }
    public func decide(_ ctx: DecisionContext) async throws -> Decision {
        Decision(ctx.menu.passive?.action ?? .fold, meta: DecisionMeta(reasoning: "Always check or call."))
    }
}

public struct RandomBot: ArenaPlayer {
    public init() {}
    public var name: String { "Random" }
    public func decide(_ ctx: DecisionContext) async throws -> Decision {
        var rng = SeededRNG(seed: ctx.rngSeed)
        var groups: [[MenuOption]] = []
        if let f = ctx.menu.first(.fold) { groups.append([f]) }
        if let p = ctx.menu.passive { groups.append([p]) }
        if !ctx.menu.aggressive.isEmpty { groups.append(ctx.menu.aggressive) }
        let g = groups[rng.below(groups.count)]
        let pick = g[rng.below(g.count)]
        return Decision(pick.action, meta: DecisionMeta(reasoning: "Random choice: \(pick.label)."))
    }
}

public struct ManiacBot: ArenaPlayer {
    public init() {}
    public var name: String { "Maniac" }
    public func decide(_ ctx: DecisionContext) async throws -> Decision {
        var rng = SeededRNG(seed: ctx.rngSeed)
        let aggr = ctx.menu.aggressive
        if !aggr.isEmpty && rng.unit() < 0.8 {
            let jam = rng.unit() < 0.1
            let pick = jam ? aggr.last! : (ctx.state.street == .preflop ? ctx.menu.sized(4) : ctx.menu.sized(rng.unit() < 0.5 ? 1.0 : 1.5))
            if let pick { return Decision(pick.action, meta: DecisionMeta(reasoning: "Maximum pressure: \(pick.label).")) }
        }
        if let l = ctx.legal, l.canFold, Chips.bb(l.toCall) > 60, rng.unit() < 0.5 {
            return Decision(.fold, meta: DecisionMeta(reasoning: "Even a maniac folds sometimes."))
        }
        return Decision(ctx.menu.passive?.action ?? .fold, meta: DecisionMeta(reasoning: "Keep the pot going."))
    }
}
