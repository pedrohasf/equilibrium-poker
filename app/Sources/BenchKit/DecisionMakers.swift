import Foundation
import LLMKit
import SolverKit

/// Anything that can answer benchmark decisions: an LLM or a reference bot.
public protocol DecisionMaker: Sendable {
    /// Stable id: OpenRouter model id or "baseline:<name>".
    var id: String { get }
    var displayName: String { get }
    var kind: PlayerKind { get }
    var options: ChatOptions? { get }
    func decide(_ decision: Decision) async throws -> DecisionResult
}

public extension DecisionMaker {
    var options: ChatOptions? { nil }
}

// MARK: - LLM

/// Asks an OpenRouter model. Network/API failures and unparseable replies become invalid answers
/// (scored as the worst legal action) rather than aborting the run; cancellation propagates.
public struct LLMDecisionMaker: DecisionMaker {
    public let model: String
    public let client: OpenRouterClient
    public let chatOptions: ChatOptions
    /// Ask once more for bare JSON when the first reply can't be parsed.
    public var repairAttempt: Bool

    public init(model: String, client: OpenRouterClient, options: ChatOptions = .init(), repairAttempt: Bool = true) {
        self.model = model
        self.client = client
        self.chatOptions = options
        self.repairAttempt = repairAttempt
    }

    public var id: String { model }
    public var displayName: String { model }
    public var kind: PlayerKind { .llm }
    public var options: ChatOptions? { chatOptions }

    public func decide(_ d: Decision) async throws -> DecisionResult {
        var messages = PromptBuilder.messages(d)
        var usage = ChatUsage()
        var latency = 0.0
        var raw = ""
        var reasoning: String?
        do {
            let r = try await client.chat(model: model, messages: messages, options: chatOptions)
            usage = usage + r.usage
            latency += r.latency
            raw = r.content
            reasoning = r.reasoning
            var choice = ResponseParser.parse(r.content, actions: d.actions)
            // Some reasoning models put the final answer only in the reasoning channel.
            if choice == nil, r.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let rs = r.reasoning {
                choice = ResponseParser.parse(rs, actions: d.actions)
            }
            if choice == nil && repairAttempt {
                messages.append(.assistant(r.content))
                messages.append(.user(PromptBuilder.repair(d)))
                let r2 = try await client.chat(model: model, messages: messages, options: chatOptions)
                usage = usage + r2.usage
                latency += r2.latency
                raw += "\n\n[repair] " + r2.content
                choice = ResponseParser.parse(r2.content, actions: d.actions)
            }
            return DecisionResult(decisionId: d.id, choice: choice, rawResponse: raw, reasoning: reasoning,
                                  error: choice == nil ? "Could not parse an action from the reply" : nil,
                                  latency: latency, promptTokens: usage.promptTokens, completionTokens: usage.completionTokens,
                                  reasoningTokens: usage.reasoningTokens, cost: usage.cost)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            return DecisionResult(decisionId: d.id, choice: nil, rawResponse: raw.isEmpty ? nil : raw, reasoning: reasoning,
                                  error: error.localizedDescription, latency: latency, promptTokens: usage.promptTokens,
                                  completionTokens: usage.completionTokens, reasoningTokens: usage.reasoningTokens, cost: usage.cost)
        }
    }
}

// MARK: - Baselines

/// Reference bots that calibrate the score scale. They need no network and are deterministic
/// per (decision, bot) so re-running a baseline reproduces it exactly.
public enum Baseline: String, CaseIterable, Codable, Sendable, DecisionMaker {
    /// Samples from the equilibrium strategy of hero's hand (≈ zero EV loss, not exactly zero).
    case gto
    /// Oracle: always the highest-EV action (EV loss 0 by construction).
    case bestEV
    /// Uniformly random legal action.
    case random
    /// Never folds or raises: check when possible, otherwise call.
    case callingStation

    public var id: String { "baseline:\(rawValue)" }
    public var kind: PlayerKind { .baseline }

    public var displayName: String {
        switch self {
        case .gto: return "GTO (sampled)"
        case .bestEV: return "Best-EV oracle"
        case .random: return "Random"
        case .callingStation: return "Calling station"
        }
    }

    public var summary: String {
        switch self {
        case .gto: return "Samples each action with its equilibrium frequency."
        case .bestEV: return "Always picks the highest-EV action — the ceiling."
        case .random: return "Picks a legal action uniformly at random."
        case .callingStation: return "Checks or calls, never folds or raises."
        }
    }

    public init?(id: String) {
        guard id.hasPrefix("baseline:"), let b = Baseline(rawValue: String(id.dropFirst(9))) else { return nil }
        self = b
    }

    public func choose(_ d: Decision) -> Int {
        var rng = SeededRNG(seed: SeededRNG.hash(d.id, d.heroCards, rawValue))
        switch self {
        case .gto: return rng.weightedIndex(d.strategy) ?? d.gtoAction
        case .bestEV: return d.bestAction
        case .random: return Int(rng.next() % UInt64(max(1, d.actions.count)))
        case .callingStation:
            return d.actions.firstIndex { $0.kind == .check } ?? d.actions.firstIndex { $0.kind == .call } ?? 0
        }
    }

    public func decide(_ d: Decision) async throws -> DecisionResult {
        DecisionResult(decisionId: d.id, choice: choose(d), rawResponse: d.actions[choose(d)].label)
    }
}
