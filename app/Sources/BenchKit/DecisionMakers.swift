import Foundation
import OpenRouterKit
import SolverKit

/// Anything that can answer benchmark decisions: a decision model or a reference bot.
public protocol DecisionMaker: Sendable {
    /// Stable id: OpenRouter model id or "baseline:<name>".
    var id: String { get }
    var displayName: String { get }
    var kind: PlayerKind { get }
    /// State/question variant id (decision models); part of the run id. nil = none / default.
    var variant: String? { get }
    func decide(_ decision: Decision) async throws -> DecisionResult
}

public extension DecisionMaker {
    var variant: String? { nil }
}

// MARK: - Decision models

/// Asks an OpenRouter System One decision model about one decision, presented with a
/// `DecisionVariant` (default `v2`: one `choice` question, see `DecisionStateBuilder`). The answer
/// maps to an action; its probabilities over the legal actions are kept so the model can also be
/// scored as a mixed strategy. Failures and unknown keys become invalid answers.
public struct DecisionModelMaker: DecisionMaker {
    public let model: String
    public let provider: any DecisionProvider
    public let presentation: DecisionVariant

    public init(model: String, provider: any DecisionProvider, variant: DecisionVariant = DecisionVariants.default) {
        self.model = model
        self.provider = provider
        self.presentation = variant
    }

    public var id: String { model }
    public var displayName: String { model }
    public var kind: PlayerKind { .decisionModel }
    public var variant: String? { presentation.id }

    public func decide(_ d: Decision) async throws -> DecisionResult {
        do {
            let (state, questions) = presentation.build(d)
            let r = try await provider.decide(model: model, state: state, questions: questions)
            return presentation.interpret(r, d)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            return DecisionResult(decisionId: d.id, choice: nil, error: error.localizedDescription)
        }
    }

    /// Maps a single-choice decisions response onto the decision's actions (pure; unit-tested).
    public static func result(_ r: DecideResult, decision d: Decision) -> DecisionResult {
        DecisionVariants.singleChoice(r, d)
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
