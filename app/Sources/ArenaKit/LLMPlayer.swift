import Foundation
import LLMKit
import SolverKit

/// What `LLMPlayer` needs from a chat backend. `OpenRouterClient` conforms; tests use mocks.
public protocol ChatProvider: Sendable {
    func complete(model: String, messages: [ChatMessage], options: ChatOptions) async throws -> LLMReply
}

public struct LLMReply: Sendable, Hashable {
    public var content: String
    public var reasoning: String?
    public var usage: ChatUsage
    public var latency: Double

    public init(content: String, reasoning: String? = nil, usage: ChatUsage = .init(), latency: Double = 0) {
        self.content = content
        self.reasoning = reasoning
        self.usage = usage
        self.latency = latency
    }
}

extension OpenRouterClient: ChatProvider {
    public func complete(model: String, messages: [ChatMessage], options: ChatOptions) async throws -> LLMReply {
        let r = try await chat(model: model, messages: messages, options: options)
        return LLMReply(content: r.content, reasoning: r.reasoning, usage: r.usage, latency: r.latency)
    }
}

/// An OpenRouter model choosing from a numbered menu of legal actions.
public struct LLMPlayer: ArenaPlayer {
    public struct Options: Sendable, Hashable {
        public var chat: ChatOptions
        /// Include the running match summary (opponent stats) in the prompt.
        public var includeMatchSummary: Bool

        public init(chat: ChatOptions = ChatOptions(temperature: nil, maxTokens: nil), includeMatchSummary: Bool = false) {
            self.chat = chat
            self.includeMatchSummary = includeMatchSummary
        }
    }

    public let model: String
    public let options: Options
    let client: any ChatProvider

    public init(model: String, options: Options = .init(), client: any ChatProvider) {
        self.model = model
        self.options = options
        self.client = client
    }

    public var name: String { model }

    public func decide(_ ctx: DecisionContext) async throws -> Decision {
        var messages = LLMPrompt.messages(for: ctx, includeSummary: options.includeMatchSummary)
        var meta = DecisionMeta()
        for attempt in 0..<2 {
            let reply: LLMReply
            do {
                reply = try await client.complete(model: model, messages: messages, options: options.chat)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                meta.errors += 1
                meta.errorMessage = error.localizedDescription
                if attempt == 0 && Task.isCancelled == false { continue }
                break
            }
            meta.raw.append(reply.content)
            meta.latency += reply.latency
            meta.promptTokens += reply.usage.promptTokens
            meta.completionTokens += reply.usage.completionTokens
            meta.reasoningTokens += reply.usage.reasoningTokens
            meta.cost += reply.usage.cost
            if let t = reply.reasoning, !t.isEmpty { meta.thinking = t }
            if let choice = LLMPrompt.parseChoice(reply.content, optionCount: ctx.menu.count) {
                meta.menuChoice = choice
                meta.reasoning = LLMPrompt.reasoningSnippet(reply.content)
                return Decision(ctx.menu[choice - 1].action, meta: meta)
            }
            meta.errors += 1
            meta.errorMessage = "could not parse an action number"
            if meta.reasoning == nil { meta.reasoning = LLMPrompt.reasoningSnippet(reply.content) }
            messages.append(.assistant(reply.content))
            messages.append(.user(LLMPrompt.correction(optionCount: ctx.menu.count)))
        }
        meta.fallback = true
        return Decision(ActionMenu.passive(for: ctx.state), meta: meta)
    }
}

// MARK: - Prompt

public enum LLMPrompt {
    public static let system = """
    You are an expert poker player in a heads-up No-Limit Texas Hold'em match. Blinds are 0.5/1 bb and both \
    stacks are reset to 100 bb every hand. Your goal is to win as many big blinds as possible over many hands \
    against the same opponent. Amounts are in big blinds (bb).

    On each turn you will see the situation and a numbered list of legal actions. Think briefly (at most a few \
    sentences), then end your reply with a JSON object on its own line choosing one option by number, exactly like:
    {"action": 3}
    """

    public static func positionName(_ seat: Int) -> String { seat == 0 ? "BTN/SB" : "BB" }

    /// Two-card text plus a human-readable suit form: "As Kd (A♠ K♦)".
    static func cards(_ cards: [Card]) -> String {
        cards.isEmpty ? "—" : "\(cards.text) (\(cards.map { "\($0.rank.char)\($0.suit.symbol)" }.joined(separator: " ")))"
    }

    /// Hand history so far from the point of view of `seat`.
    public static func history(_ state: HandState, seat: Int) -> String {
        func who(_ s: Int) -> String { s == seat ? "You" : "Opponent" }
        let cfg = state.config
        var lines: [String] = []
        for street in Street.allCases where street.rawValue <= state.street.rawValue || state.actions.contains(where: { $0.street == street }) {
            var parts: [String] = []
            if street == .preflop {
                parts.append("\(who(0)) (BTN/SB) post\(seat == 0 ? "" : "s") \(Chips.text(cfg.smallBlind)), \(who(1)) (BB) post\(seat == 1 ? "" : "s") \(Chips.text(cfg.bigBlind))")
            }
            for a in state.actions where a.street == street {
                let v: String
                switch a.kind {
                case .fold: v = a.seat == seat ? "fold" : "folds"
                case .check: v = a.seat == seat ? "check" : "checks"
                case .call: v = (a.seat == seat ? "call " : "calls ") + Chips.text(a.amount)
                case .bet: v = (a.seat == seat ? "bet " : "bets ") + Chips.text(a.to)
                case .raise: v = (a.seat == seat ? "raise to " : "raises to ") + Chips.text(a.to)
                }
                parts.append("\(who(a.seat)) \(v)\(a.allIn ? " (all-in)" : "")")
            }
            let boardText = street == .preflop ? "" : " [\(state.runout.prefix(street.boardCount).map(\.description).joined(separator: " "))]"
            lines.append("\(street.name)\(boardText): " + (parts.isEmpty ? "—" : parts.joined(separator: ", ")) + ".")
        }
        return lines.joined(separator: "\n")
    }

    public static func userPrompt(for ctx: DecisionContext, includeSummary: Bool) -> String {
        let s = ctx.state
        let me = ctx.seat, opp = 1 - ctx.seat
        let l = ctx.legal
        var out = """
        Hand #\(ctx.handNumber) — Heads-up NLHE, blinds 0.5/1 bb, starting stacks \(Chips.text(s.config.stacks[me])) bb.
        Your position: \(positionName(me)) (\(me == 0 ? "you act first preflop and last after the flop" : "you act last preflop and first after the flop")).
        Your hole cards: \(cards(ctx.hole))
        Board: \(s.board.isEmpty ? "none yet (preflop)" : cards(s.board)) — \(s.street.name.lowercased())
        Pot: \(Chips.text(s.pot)) bb (including all bets so far)
        Stacks behind: you \(Chips.text(s.stacks[me])) bb, opponent \(Chips.text(s.stacks[opp])) bb
        This street: you have put in \(Chips.text(s.streetContrib[me])) bb, opponent \(Chips.text(s.streetContrib[opp])) bb\(l.map { $0.toCall > 0 ? ". To call: \(Chips.text($0.toCall)) bb" : "" } ?? "").

        Action so far:
        \(history(s, seat: me))
        """
        if includeSummary, let sum = ctx.matchSummary, !sum.isEmpty {
            out += "\n\nMatch so far:\n\(sum)"
        }
        out += "\n\nLegal actions:\n"
        out += ctx.menu.enumerated().map { "\($0.offset + 1). \($0.element.label)" }.joined(separator: "\n")
        out += "\n\nThink briefly, then end with {\"action\": <number>}."
        return out
    }

    public static func messages(for ctx: DecisionContext, includeSummary: Bool) -> [ChatMessage] {
        [.system(system), .user(userPrompt(for: ctx, includeSummary: includeSummary))]
    }

    public static func correction(optionCount: Int) -> String {
        "I could not read a valid choice. Reply with only a JSON object such as {\"action\": 1}, where the number is between 1 and \(optionCount)."
    }

    /// Extracts the chosen 1-based option, validating the range.
    public static func parseChoice(_ text: String, optionCount: Int) -> Int? {
        func valid(_ n: Int?) -> Int? { n.flatMap { (1...max(1, optionCount)).contains($0) ? $0 : nil } }
        if let obj = LLMParsing.lastJSONObject(in: text) {
            for key in ["action", "choice", "option"] {
                if let n = obj[key] as? NSNumber { return valid(n.intValue) }
                if let s = obj[key] as? String { return valid(Int(s.trimmingCharacters(in: .whitespaces).filter(\.isNumber))) }
            }
        }
        // Lenient fallbacks: `"action": 3` without braces, or a bare number as the whole reply.
        if let re = try? NSRegularExpression(pattern: #"\"?action\"?\s*[:=]\s*\"?(\d+)"#, options: .caseInsensitive) {
            let ns = text as NSString
            if let m = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last {
                return valid(Int(ns.substring(with: m.range(at: 1))))
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(trimmed) { return valid(n) }
        return nil
    }

    /// The reasoning text before the final JSON, trimmed to a readable snippet.
    public static func reasoningSnippet(_ text: String, limit: Int = 600) -> String? {
        var t = text
        if let r = t.range(of: "{", options: .backwards) { t = String(t[..<r.lowerBound]) }
        t = t.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return t.count > limit ? String(t.prefix(limit)) + "…" : t
    }
}
