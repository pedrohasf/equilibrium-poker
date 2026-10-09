import Foundation
import LLMKit
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

/// Serializable description of a participant: a bot or an OpenRouter model.
public struct PlayerSpec: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case bot, llm }

    public var kind: Kind
    /// Bot raw value ("tag") or OpenRouter model id ("openai/gpt-5").
    public var model: String
    public var reasoningEffort: String?

    public init(kind: Kind, model: String, reasoningEffort: String? = nil) {
        self.kind = kind
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

    public static func bot(_ b: BotKind) -> PlayerSpec { PlayerSpec(kind: .bot, model: b.rawValue) }
    public static func llm(_ model: String, effort: String? = nil) -> PlayerSpec { PlayerSpec(kind: .llm, model: model, reasoningEffort: effort) }

    /// Stable key used by the leaderboard: "bot:tag", "openai/gpt-5", "openai/gpt-5@low".
    public var id: String {
        switch kind {
        case .bot: return "bot:\(model)"
        case .llm: return model + (reasoningEffort.map { "@\($0)" } ?? "")
        }
    }

    public var bot: BotKind? { kind == .bot ? BotKind(rawValue: model) : nil }

    /// Short display name ("gpt-5", "TAG bot").
    public var displayName: String {
        if let b = bot { return b.title }
        let base = String(model.split(separator: "/").last ?? Substring(model))
        return base + (reasoningEffort.map { " · \($0)" } ?? "")
    }

    /// Provider segment ("openai") or "bot".
    public var provider: String {
        kind == .bot ? "bot" : String(model.split(separator: "/").first ?? "")
    }

    /// Parses "bot:tag", "tag", "random", "openai/gpt-5", "openai/gpt-5@low".
    public static func parse(_ text: String) -> PlayerSpec? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let lower = t.lowercased()
        let botName = lower.hasPrefix("bot:") ? String(lower.dropFirst(4)) : lower
        let aliases: [String: BotKind] = ["tag": .tag, "station": .station, "calling-station": .station, "callingstation": .station,
                                          "maniac": .maniac, "random": .random]
        if let b = aliases[botName] { return .bot(b) }
        if lower.hasPrefix("bot:") { return nil }
        guard t.contains("/") else { return nil }
        let parts = t.split(separator: "@", maxSplits: 1).map(String.init)
        return .llm(parts[0], effort: parts.count > 1 ? parts[1] : nil)
    }
}

public enum PlayerFactory {
    /// Builds a player. LLM players require a chat provider.
    public static func make(_ spec: PlayerSpec, chat: (any ChatProvider)?, options: LLMPlayer.Options = .init()) throws -> any ArenaPlayer {
        switch spec.kind {
        case .bot:
            switch spec.bot {
            case .tag: return TightAggressiveBot()
            case .station: return CallingStation()
            case .maniac: return ManiacBot()
            case .random: return RandomBot()
            case nil: throw EngineError("unknown bot '\(spec.model)'")
            }
        case .llm:
            guard let chat else { throw EngineError("an OpenRouter API key is required for \(spec.model)") }
            var o = options
            o.chat.reasoningEffort = spec.reasoningEffort ?? o.chat.reasoningEffort
            return LLMPlayer(model: spec.model, options: o, client: chat)
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
