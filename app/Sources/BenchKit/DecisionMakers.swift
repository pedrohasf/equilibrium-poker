import Foundation
import OpenRouterKit
import SolverKit

/// Anything that can answer benchmark decisions: a decision model or a reference bot.
public protocol DecisionMaker: Sendable {
    /// Stable id: OpenRouter model id or "baseline:<name>".
    var id: String { get }
    var displayName: String { get }
    var kind: PlayerKind { get }
    func decide(_ decision: Decision) async throws -> DecisionResult
}

// MARK: - Decision models

/// Asks an OpenRouter System One decision model one `choice` question (see `DecisionStateBuilder`).
/// The returned key maps to the action; its probabilities over the legal actions are kept so the
/// model can also be scored as a mixed strategy. Failures and unknown keys become invalid answers.
public struct DecisionModelMaker: DecisionMaker {
    public let model: String
    public let provider: any DecisionProvider

    public init(model: String, provider: any DecisionProvider) {
        self.model = model
        self.provider = provider
    }

    public var id: String { model }
    public var displayName: String { model }
    public var kind: PlayerKind { .decisionModel }

    public func decide(_ d: Decision) async throws -> DecisionResult {
        do {
            let r = try await provider.decide(model: model, state: DecisionStateBuilder.state(d),
                                              questions: DecisionStateBuilder.questions(d))
            return Self.result(r, decision: d)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            return DecisionResult(decisionId: d.id, choice: nil, error: error.localizedDescription)
        }
    }

    /// Maps a decisions response onto the decision's actions (pure; unit-tested).
    public static func result(_ r: DecideResult, decision d: Decision) -> DecisionResult {
        func invalid(_ why: String) -> DecisionResult {
            DecisionResult(decisionId: d.id, choice: nil, rawResponse: r.raw, error: why, latency: r.latency,
                           promptTokens: r.usage.promptTokens, completionTokens: r.usage.completionTokens, cost: r.usage.cost)
        }
        guard let answer = r.answers[DecisionStateBuilder.questionId] ?? (r.answers.count == 1 ? r.answers.first?.value : nil),
              case .choice(let key, let confidence, let probs) = answer else {
            return invalid("No choice answer in the response")
        }
        guard let choice = DecisionStateBuilder.actionIndex(forKey: key, actions: d.actions) else {
            return invalid("Unknown action key '\(key)'")
        }
        var vector = Array(repeating: 0.0, count: d.actions.count)
        for (k, p) in probs {
            if let i = DecisionStateBuilder.actionIndex(forKey: k, actions: d.actions), p.isFinite, p > 0 { vector[i] += p }
        }
        let p = Scoring.normalized(vector) ?? vector.indices.map { $0 == choice ? 1 : 0 }
        return DecisionResult(decisionId: d.id, choice: choice, rawResponse: r.raw, latency: r.latency,
                              promptTokens: r.usage.promptTokens, completionTokens: r.usage.completionTokens, cost: r.usage.cost,
                              actionProbabilities: p, confidence: confidence)
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
        DecisionResult(decisionId: d.id, choice: choose(d), rawResponse: d.actions[choose(d)].label,
                       actionProbabilities: self == .gto ? Scoring.normalized(d.strategy) : nil)
    }
}
