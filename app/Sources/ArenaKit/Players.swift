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

/// How a decision-model player turns the returned probabilities into an action.
public enum DecisionMode: String, Codable, Sendable, CaseIterable {
    /// Play the model's top choice.
    case argmax
    /// Sample from the returned probabilities (seeded), i.e. play a randomized strategy.
    case mixed

    public var title: String { self == .argmax ? "Argmax" : "Mixed" }
}

/// Serializable description of a participant: a bot, an OpenRouter chat model or a System One decision model.
public struct PlayerSpec: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case bot, llm, decision }

    public var kind: Kind
    /// Bot raw value ("tag") or OpenRouter model id ("openai/gpt-5", "typesafe/jev-1.13").
    public var model: String
    public var reasoningEffort: String?
    /// Decision models only (nil = argmax). Optional so matches saved before decision models still decode.
    public var decisionMode: DecisionMode?

    public init(kind: Kind, model: String, reasoningEffort: String? = nil, decisionMode: DecisionMode? = nil) {
        self.kind = kind
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.decisionMode = decisionMode
    }

    public static func bot(_ b: BotKind) -> PlayerSpec { PlayerSpec(kind: .bot, model: b.rawValue) }
    public static func llm(_ model: String, effort: String? = nil) -> PlayerSpec { PlayerSpec(kind: .llm, model: model, reasoningEffort: effort) }
    public static func decision(_ model: String, mode: DecisionMode = .argmax) -> PlayerSpec {
        PlayerSpec(kind: .decision, model: model, decisionMode: mode)
    }

    public var isDecisionModel: Bool { kind == .decision }
    /// True for anything that calls OpenRouter (needs an API key).
    public var usesOpenRouter: Bool { kind != .bot }
    public var mode: DecisionMode { decisionMode ?? .argmax }

    /// Stable key used by the leaderboard: "bot:tag", "openai/gpt-5", "openai/gpt-5@low",
    /// "dm:typesafe/jev-1.13", "dm:typesafe/jev-1.13~mix".
    public var id: String {
        switch kind {
        case .bot: return "bot:\(model)"
        case .llm: return model + (reasoningEffort.map { "@\($0)" } ?? "")
        case .decision: return "dm:\(model)" + (mode == .mixed ? "~mix" : "")
        }
    }

    public var bot: BotKind? { kind == .bot ? BotKind(rawValue: model) : nil }

    /// Short display name ("gpt-5", "TAG bot", "jev-1.13 · mixed").
    public var displayName: String {
        if let b = bot { return b.title }
        let base = String(model.split(separator: "/").last ?? Substring(model))
        if kind == .decision { return base + (mode == .mixed ? " · mixed" : "") }
        return base + (reasoningEffort.map { " · \($0)" } ?? "")
    }

    /// Provider segment ("openai") or "bot".
    public var provider: String {
        kind == .bot ? "bot" : String(model.split(separator: "/").first ?? "")
    }

    /// Parses "bot:tag", "tag", "random", "openai/gpt-5", "openai/gpt-5@low",
    /// "dm:typesafe/jev-1.13", "dm:typesafe/jev-1.13~mix" (a bare "<id>~mix" is also a decision model).
    /// Plain ids parse as chat models; use `resolvingDecisionModels` to auto-detect decision models.
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
        var isDecision = false
        for prefix in ["dm:", "decision:"] where lower.hasPrefix(prefix) {
            body = String(t.dropFirst(prefix.count))
            isDecision = true
        }
        var mode: DecisionMode?
        if let r = body.range(of: "~", options: .backwards) {
            switch body[r.upperBound...].lowercased() {
            case "mix", "mixed", "sample": mode = .mixed
            case "argmax", "max", "top": mode = .argmax
            default: return nil
            }
            body = String(body[..<r.lowerBound])
            isDecision = true
        }
        guard body.contains("/") else { return nil }
        if isDecision {
            guard !body.contains("@") else { return nil }
            return .decision(body, mode: mode ?? .argmax)
        }
        let parts = body.split(separator: "@", maxSplits: 1).map(String.init)
        return .llm(parts[0], effort: parts.count > 1 ? parts[1] : nil)
    }

    /// Turns a plain chat spec into a decision spec when its id is a known decision model.
    public func resolvingDecisionModels(_ decisionIDs: Set<String>) -> PlayerSpec {
        guard kind == .llm, reasoningEffort == nil, decisionIDs.contains(model) else { return self }
        return .decision(model)
    }
}

public enum PlayerFactory {
    /// Builds a player. LLM players require a chat provider; decision models a decision provider.
    public static func make(_ spec: PlayerSpec, chat: (any ChatProvider)?, decisions: (any DecisionProvider)? = nil,
                            options: LLMPlayer.Options = .init()) throws -> any ArenaPlayer {
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
        case .decision:
            guard let decisions = decisions ?? (chat as? any DecisionProvider) else {
                throw EngineError("an OpenRouter API key is required for \(spec.model)")
            }
            return DecisionModelPlayer(model: spec.model, mode: spec.mode, includeMatchSummary: options.includeMatchSummary,
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
