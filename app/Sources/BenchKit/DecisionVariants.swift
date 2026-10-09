import Foundation
import OpenRouterKit
import SolverKit

/// A named way of presenting a decision to a decision model: the `state` it reads, the questions
/// it answers, and how the answers become one probability vector over the legal actions.
///
/// Every variant uses the same legal-action keys (`DecisionStateBuilder.actionKeys`) and key
/// parsing, so results are comparable across variants. Variants must never leak solver data (GTO
/// strategy, EVs, solver equity, villain cards). To add one: write a `DecisionVariant` and append
/// it to `DecisionVariants.all` — `eqbench bench run --variant <id>` picks it up, and the id
/// becomes part of the run id and label (`typesafe/jev-1.13 [id]`).
public struct DecisionVariant: Sendable, Identifiable {
    public let id: String
    /// One line for `--help`, reports and exports.
    public let summary: String
    public let build: @Sendable (Decision) -> (state: JSONValue, questions: [String: DecisionQuestion])
    /// Maps the API response onto the decision's actions (pure).
    public let interpret: @Sendable (DecideResult, Decision) -> DecisionResult

    public init(id: String, summary: String,
                build: @escaping @Sendable (Decision) -> (state: JSONValue, questions: [String: DecisionQuestion]),
                interpret: @escaping @Sendable (DecideResult, Decision) -> DecisionResult) {
        self.id = id
        self.summary = summary
        self.build = build
        self.interpret = interpret
    }

    /// The exact request body (minus auth) for display, the CLI and token estimates.
    public func requestBody(_ d: Decision, model: String = "<decision-model>") -> JSONValue {
        let (state, questions) = build(d)
        return ["model": .string(model), "state": state, "questions": .object(questions.mapValues(\.json))]
    }

    /// Compact JSON characters / 3.1 — calibrated on billed TypeSafe Jev input tokens (multi, noul).
    public func estimatedInputTokens(_ d: Decision) -> Int {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let n = (try? e.encode(requestBody(d)).count) ?? requestBody(d).prettyText.count / 2
        return Int((Double(n) / 3.1).rounded())
    }
}

public enum DecisionVariants {
    public static let defaultId = "v2"

    /// Registry, in display order.
    public static let all: [DecisionVariant] = [v2, minimal, eq, eqrange, coach, multi, noul, nuts, shortstack]

    public static func named(_ id: String) -> DecisionVariant? { all.first { $0.id == id.lowercased() } }
    public static var `default`: DecisionVariant { v2 }
    public static var ids: [String] { all.map(\.id) }

    typealias B = DecisionStateBuilder

    // MARK: Variants

    /// The original state (cards, positions, betting by street, pot odds, SPR, made hand, draws, texture)
    /// and one `choice` question whose criteria explain each action.
    public static let v2 = DecisionVariant(
        id: "v2", summary: "Default: full state with derived facts (made hand, draws, pot odds, SPR) + one choice question",
        build: { d in (B.state(d), B.questions(d)) },
        interpret: { r, d in singleChoice(r, d) })

    /// Only raw facts: cards, positions, pot/stacks/to-call, the betting history and the legal actions.
    /// No made-hand/draw/texture/pot-odds facts; criteria are the bare action labels.
    public static let minimal = DecisionVariant(
        id: "minimal", summary: "Raw facts only (cards, positions, pot/stacks/to-call, history, actions); no derived facts",
        build: { d in
            (minimalState(d), [B.questionId: .choice(instructions: minimalInstructions,
                                                       criteria: Dictionary(uniqueKeysWithValues: zip(B.actionKeys(d.actions), d.actions.map(\.detailedLabel))))])
        },
        interpret: { r, d in singleChoice(r, d) })

    /// v2 + hero's Monte-Carlo equity vs the villain's *preflop* range, made-hand percentile vs that
    /// range, and an explicit "equity vs needed" comparison.
    public static let eq = DecisionVariant(
        id: "eq", summary: "v2 + hero equity and made-hand percentile vs villain's preflop range (Monte-Carlo), equity vs needed",
        build: { d in
            let f = EquityTools.facts(d)
            return (withEquity(B.state(d), d, f, narrowed: false), [B.questionId: .choice(instructions: B.instructions, criteria: equityCriteria(d, f, narrowed: false))])
        },
        interpret: { r, d in singleChoice(r, d) })

    /// Like `eq`, but the equity is against the villain's range narrowed by the villain's actions so far
    /// (`EquityTools.narrowedWeights` heuristic — no solver data). The preflop-range equity is shown too.
    public static let eqrange = DecisionVariant(
        id: "eqrange", summary: "eq, but equity vs villain's range narrowed by its actions (strength heuristic, no solver data)",
        build: { d in
            let f = EquityTools.facts(d)
            return (withEquity(B.state(d), d, f, narrowed: true), [B.questionId: .choice(instructions: B.instructions, criteria: equityCriteria(d, f, narrowed: true))])
        },
        interpret: { r, d in singleChoice(r, d) })

    /// v2 state; instructions and criteria rewritten as concise poker theory (value / bluff / bluff-catch,
    /// MDF, polarisation) and an explicit request for balanced play against a GTO opponent.
    public static let coach = DecisionVariant(
        id: "coach", summary: "v2 state; criteria rewritten as concise GTO theory (value/bluff/bluff-catch, MDF, polarisation)",
        build: { d in (B.state(d), [B.questionId: .choice(instructions: coachInstructions, criteria: coachCriteria(d))]) },
        interpret: { r, d in singleChoice(r, d) })

    /// v2 state; the same choice asked three times with different instructions (v2, coach, solver-frequency
    /// phrasing), answered independently in one request. The result averages the three probability vectors.
    public static let multi = DecisionVariant(
        id: "multi", summary: "v2 state; 3 independently answered choice questions (v2 / coach / solver phrasing), probabilities averaged",
        build: { d in
            (B.state(d), [
                multiIds[0]: .choice(instructions: B.instructions, criteria: B.criteria(d)),
                multiIds[1]: .choice(instructions: coachInstructions, criteria: coachCriteria(d)),
                multiIds[2]: .choice(instructions: solverInstructions, criteria: B.criteria(d)),
            ])
        },
        interpret: { r, d in averagedChoices(r, d, ids: multiIds) })

    /// v2 state; one yes/no (`noul`) question per legal action — "is this the highest-EV action?" — and
    /// P(true) normalised across actions becomes the distribution.
    public static let noul = DecisionVariant(
        id: "noul", summary: "v2 state; one noul per action ('is <action> the highest-EV action?'), P(true) normalised",
        build: { d in
            let keys = B.actionKeys(d.actions)
            var qs: [String: DecisionQuestion] = [:]
            for (i, a) in d.actions.enumerated() {
                qs[noulPrefix + keys[i]] = .noul(
                    instructions: "Decide whether this specific legal action is the single highest-expected-value action for the hero "
                        + "in the spot described in the state, against a strong, balanced, game-theory-optimal opponent who cannot see "
                        + "the hero's cards. The action: \(B.describe(a, d)) The other legal actions are: "
                        + d.actions.indices.filter { $0 != i }.map { d.actions[$0].detailedLabel }.joined(separator: "; ") + ".",
                    whenTrue: "\(a.detailedLabel) earns at least as much as every other legal action with the hero's exact hand.",
                    whenFalse: "Some other legal action earns more than \(a.detailedLabel) with the hero's exact hand.")
            }
            return (B.state(d), qs)
        },
        interpret: { r, d in noulPerAction(r, d) })

    static let multiIds = ["action", "action_coach", "action_solver"]
    static let noulPrefix = "best_"

    // MARK: Answer interpretation (pure; unit-tested)

    static func base(_ r: DecideResult, _ d: Decision) -> DecisionResult {
        DecisionResult(decisionId: d.id, choice: nil, rawResponse: r.raw, latency: r.latency,
                       promptTokens: r.usage.promptTokens, completionTokens: r.usage.completionTokens, cost: r.usage.cost)
    }

    static func invalid(_ r: DecideResult, _ d: Decision, _ why: String, parts: [AnswerPart]? = nil) -> DecisionResult {
        var x = base(r, d)
        x.error = why
        x.parts = parts
        return x
    }

    /// Probability vector of one choice answer (one-hot on the choice if no probabilities), or nil if the key is unknown.
    static func vector(_ answer: DecisionAnswer, _ d: Decision) -> (choice: Int, p: [Double], confidence: Double?)? {
        guard case .choice(let key, let confidence, let probs) = answer,
              let choice = B.actionIndex(forKey: key, actions: d.actions) else { return nil }
        var v = Array(repeating: 0.0, count: d.actions.count)
        for (k, p) in probs {
            if let i = B.actionIndex(forKey: k, actions: d.actions), p.isFinite, p > 0 { v[i] += p }
        }
        return (choice, Scoring.normalized(v) ?? v.indices.map { $0 == choice ? 1 : 0 }, confidence)
    }

    /// One choice question (`action`, or the only answer).
    public static func singleChoice(_ r: DecideResult, _ d: Decision) -> DecisionResult {
        guard let answer = r.answers[B.questionId] ?? (r.answers.count == 1 ? r.answers.first?.value : nil),
              case .choice(let key, _, _) = answer else {
            return invalid(r, d, "No choice answer in the response")
        }
        guard let v = vector(answer, d) else { return invalid(r, d, "Unknown action key '\(key)'") }
        var x = base(r, d)
        x.choice = v.choice
        x.actionProbabilities = v.p
        x.confidence = v.confidence
        return x
    }

    /// Averages the probability vectors of several choice questions; the choice is the argmax of the
    /// average. Missing/unknown answers are skipped (recorded in `parts`); none valid → invalid.
    public static func averagedChoices(_ r: DecideResult, _ d: Decision, ids: [String]) -> DecisionResult {
        var parts: [AnswerPart] = []
        var vectors: [[Double]] = []
        var confs: [Double] = []
        for id in ids {
            guard let a = r.answers[id], let v = vector(a, d) else {
                parts.append(AnswerPart(id: id))
                continue
            }
            parts.append(AnswerPart(id: id, choice: v.choice, probabilities: v.p))
            vectors.append(v.p)
            if let c = v.confidence { confs.append(c) }
        }
        guard !vectors.isEmpty else { return invalid(r, d, "No valid choice answer among \(ids.joined(separator: ", "))", parts: parts) }
        let avg = d.actions.indices.map { i in vectors.reduce(0) { $0 + $1[i] } / Double(vectors.count) }
        var x = base(r, d)
        x.choice = argmax(avg)
        x.actionProbabilities = avg
        x.confidence = confs.isEmpty ? nil : confs.reduce(0, +) / Double(confs.count)
        x.parts = parts
        return x
    }

    /// One noul per action: P(true) normalised across actions. Any missing answer → invalid.
    public static func noulPerAction(_ r: DecideResult, _ d: Decision) -> DecisionResult {
        let keys = B.actionKeys(d.actions)
        var parts: [AnswerPart] = []
        var ps: [Double] = []
        for (i, k) in keys.enumerated() {
            guard case .noul(let p)? = r.answers[noulPrefix + k], p.isFinite else {
                parts.append(AnswerPart(id: noulPrefix + k, choice: i))
                continue
            }
            parts.append(AnswerPart(id: noulPrefix + k, choice: i, pTrue: p))
            ps.append(max(0, p))
        }
        guard ps.count == keys.count else { return invalid(r, d, "Missing noul answers (\(ps.count)/\(keys.count))", parts: parts) }
        let dist = Scoring.normalized(ps) ?? ps.map { _ in 1 / Double(ps.count) }
        var x = base(r, d)
        x.choice = argmax(dist)
        x.actionProbabilities = dist
        x.confidence = ps.max()
        x.parts = parts
        return x
    }

    static func argmax(_ v: [Double]) -> Int { v.indices.max { v[$0] < v[$1] } ?? 0 }

    // MARK: Texts

    static let minimalInstructions = """
    You are the hero, the player to act in the heads-up No-Limit Texas Hold'em hand described in the state. \
    Choose the legal action with the highest expected value against a strong, balanced, game-theory-optimal opponent \
    who cannot see your cards.
    """

    static let coachInstructions = """
    You are an expert poker coach applying game theory. Choose the action a balanced, game-theory-optimal (GTO) \
    strategy plays most often with the hero's exact hand in this heads-up No-Limit Hold'em spot. The opponent is \
    also GTO and punishes imbalance: do not over-fold (defend roughly the minimum defence frequency with the best \
    part of the range), do not over-bluff, value-bet hands that are ahead of the hands that call, bluff with hands \
    that have little showdown value but good blockers or draws, and check/call medium-strength hands that want \
    to reach showdown cheaply. Think about the hero's whole range in this spot and where this hand sits in it.
    """

    static let solverInstructions = """
    Imagine a poker solver has computed the equilibrium strategy for this heads-up No-Limit Hold'em spot. \
    Which legal action does the solver's strategy choose most often with the hero's exact hole cards, given the board, \
    the betting so far, the stack-to-pot ratio and position? Answer as the solver would, not as a cautious human.
    """

    // MARK: State builders

    static func minimalState(_ d: Decision) -> JSONValue {
        let names = [d.positions[0] + (d.heroSeat == 0 ? " (hero)" : " (villain)"),
                     d.positions[1] + (d.heroSeat == 1 ? " (hero)" : " (villain)")]
        var streets: [JSONValue] = []
        for street in Street.historyStreets(upTo: d.street) {
            let cards: [String]
            switch street {
            case .preflop: cards = []
            case .flop: cards = Array(d.board.prefix(3))
            case .turn: cards = d.board.count > 3 ? [d.board[3]] : []
            case .river: cards = d.board.count > 4 ? [d.board[4]] : []
            }
            var acts = d.history.filter { $0.street == street && $0.action != nil }.map { JSONValue.string($0.text(names: names)) }
            if street == d.street { acts.append(.string("\(names[d.heroSeat]) to act")) }
            streets.append(["street": .string(street.rawValue), "new_cards": .string(cards.joined(separator: " ")), "actions": .array(acts)])
        }
        let keys = B.actionKeys(d.actions)
        return [
            "game": .string("No-Limit Texas Hold'em, heads-up \(d.street == .preflop ? "preflop; SB is the button (acts first preflop, last postflop)" : "postflop"), "
                + "amounts in big blinds (bb). " + B.setupText(d)),
            "preflop": .string(d.preflopSummary),
            "hero": ["position": .string(d.heroPosition), "in_position": .bool(d.heroIsIP),
                     "hole_cards": .string((Card.parseList(d.heroCards) ?? []).map(\.description).joined(separator: " "))],
            "villain": ["position": .string(d.villainPosition)],
            "board": .string(d.board.joined(separator: " ")),
            "betting_by_street": .array(streets),
            "pot_bb": B.num(d.pot),
            "hero_stack_bb": B.num(d.stacks[d.heroSeat]),
            "villain_stack_bb": B.num(d.stacks[1 - d.heroSeat]),
            "amount_to_call_bb": B.num(d.toCall),
            "legal_actions": .array(d.actions.enumerated().map { i, a in ["key": .string(keys[i]), "label": .string(a.detailedLabel)] }),
        ]
    }

    /// Adds equity facts to the v2 state's `hero` and `spot` objects.
    static func withEquity(_ state: JSONValue, _ d: Decision, _ f: EquityTools.Facts?, narrowed: Bool) -> JSONValue {
        guard let f, case .object(var root) = state, case .object(var hero)? = root["hero"], case .object(var spot)? = root["spot"] else {
            return state
        }
        if d.street == .preflop {
            // Preflop: equity vs any two cards and vs the villain's plausible range (heuristic) — all-in equity, no realisation.
            hero["equity_vs_random_hand_pct"] = B.num(f.equityPreflop * 100, 10)
            hero["hand_beats_pct_of_random_hands"] = B.num(f.percentilePreflop * 100, 10)
            var note = "Equity = hero's all-in showdown equity over a full five-card board against a random hand"
            if narrowed {
                hero["equity_vs_villain_plausible_range_pct"] = B.num(f.equityNarrowed * 100, 10)
                note += "; the 'plausible range' keeps the hands a solid player usually takes the villain's actions with "
                    + "(raises and all-ins: stronger hands; calls: medium and strong hands; limps and checks: fewer of the strongest)"
            }
            hero["equity_note"] = .string(note + ". Out of position, equity is realised less than fully.")
            let eq = narrowed ? f.equityNarrowed : f.equityPreflop
            if d.facingBet {
                let need = B.potOdds(d)
                spot["equity_vs_needed"] = .string("hero equity \(BB.pct(eq)) vs \(BB.pct(need)) needed to call (raw all-in equity)")
            }
            root["hero"] = .object(hero)
            root["spot"] = .object(spot)
            return .object(root)
        }
        hero["equity_vs_villain_preflop_range_pct"] = B.num(f.equityPreflop * 100, 10)
        hero["made_hand_beats_pct_of_villain_preflop_range"] = B.num(f.percentilePreflop * 100, 10)
        var note = "Equity = hero's chance to win at showdown (Monte-Carlo over the remaining cards) against every hand the villain's "
            + "preflop range can hold on this board"
        if narrowed {
            hero["equity_vs_villain_likely_range_pct"] = B.num(f.equityNarrowed * 100, 10)
            hero["made_hand_beats_pct_of_villain_likely_range"] = B.num(f.percentileNarrowed * 100, 10)
            note += "; the 'likely range' re-weights that range by the villain's bets, calls and checks so far "
                + "(bets/raises keep mostly strong hands and draws, calls drop the weakest hands, checks drop some of the strongest)"
        } else {
            note += ", not narrowed by the betting (the villain's real range is usually stronger after bets and raises)"
        }
        hero["equity_note"] = .string(note + ".")
        let eq = narrowed ? f.equityNarrowed : f.equityPreflop
        if d.facingBet {
            let need = B.potOdds(d)
            spot["equity_vs_needed"] = .string("hero equity \(BB.pct(eq)) vs \(BB.pct(need)) needed to call "
                + (eq >= need ? "(enough on raw equity)" : "(short of the price on raw equity)"))
        }
        root["hero"] = .object(hero)
        root["spot"] = .object(spot)
        return .object(root)
    }

    /// v2 criteria; fold/call mention the equity comparison.
    static func equityCriteria(_ d: Decision, _ f: EquityTools.Facts?, narrowed: Bool) -> [String: String] {
        var c = B.criteria(d)
        guard let f, d.facingBet else { return c }
        let eq = narrowed ? f.equityNarrowed : f.equityPreflop
        let what = d.street == .preflop ? (narrowed ? "the villain's plausible range" : "a random hand")
            : narrowed ? "the villain's likely (action-narrowed) range" : "the villain's whole preflop range"
        let line = " Hero's estimated equity vs \(what) is \(BB.pct(eq)) against \(BB.pct(B.potOdds(d))) needed."
        let keys = B.actionKeys(d.actions)
        for (i, a) in d.actions.enumerated() where a.kind == .fold || a.kind == .call { c[keys[i]] = (c[keys[i]] ?? "") + line }
        return c
    }

    /// Concise theory per action, with this spot's numbers (MDF, required equity, bluff ratio).
    static func coachCriteria(_ d: Decision) -> [String: String] {
        let keys = B.actionKeys(d.actions)
        let need = B.potOdds(d)
        let potBefore = max(d.pot - d.toCall, 1e-9)
        let mdf = d.facingBet ? potBefore / (potBefore + d.toCall) : 0
        let river = d.street == .river
        var out: [String: String] = [:]
        for (i, a) in d.actions.enumerated() {
            let text: String
            switch a.kind {
            case .fold:
                text = "Fold (forfeit the \(BB.fmt(d.pot)) bb pot): only with the weakest part of the hero's range here. Calling needs \(BB.pct(need)) equity; "
                    + "against a balanced bettor the hero must still continue with about \(BB.pct(mdf)) of its range (minimum defence frequency = pot/(pot+bet)), "
                    + "so fold hands that beat almost none of the villain's bluffs and have no draw or blocker value."
            case .check:
                text = "Check (pot stays \(BB.fmt(d.pot)) bb): for medium-strength hands that want a cheap showdown (pot control / bluff-catching), "
                    + "for weak hands that are poor bluffs, and for some strong hands that protect the checking range. "
                    + (d.heroIsIP ? (river ? "Checking back goes to showdown." : "Checking back takes a free card.")
                        : "Out of position, check much of the range when the board favours the villain.")
            case .call:
                text = "Call \(BB.fmt(a.amount)) bb (bluff-catch / continue): needs \(BB.pct(need)) equity vs the villain's betting range. "
                    + "Right for hands that beat the villain's bluffs and some thin value but are not strong enough to raise for value"
                    + (river ? "." : ", and for draws with good implied odds.")
            case .bet:
                let f = a.potFraction
                let bluffShare = f / (1 + 2 * f)
                text = "Bet \(BB.fmt(a.amount)) bb (\(BB.pct(f)) pot): " + (f <= 0.5
                    ? "a small bet works as a range bet — thin value, protection and cheap bluffs with many hands when the board favours the hero's range."
                    : "a large, polarised bet: strong value hands that worse hands call, plus bluffs with blockers or draws. ")
                    + (f > 0.5 ? "A balanced \(river ? "river " : "")betting range at this size is roughly \(BB.pct(1 - bluffShare)) value / \(BB.pct(bluffShare)) bluffs." : "")
            case .raise:
                text = "Raise to \(BB.fmt(a.to)) bb: polarised — value hands well ahead of the villain's calling range, plus some bluffs/semi-bluffs "
                    + "with blockers or strong draws. Medium hands prefer calling."
            case .allin:
                text = "All-in for \(BB.fmt(a.amount)) bb: the most polarised action — the very strongest hands and a matching share of bluffs "
                    + "(blockers to the villain's calls). Never with medium hands that are only ahead of bluffs."
            }
            out[keys[i]] = text
        }
        return out
    }
}
