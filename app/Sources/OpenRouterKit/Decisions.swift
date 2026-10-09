import Foundation

// MARK: - System One / Decisions API
//
// Decision models (e.g. TypeSafe Jev, Liquid d1, Cloudflare Clef, GPT-6 Luna Decisions)
// don't generate text. They read a `state` and answer typed questions with
// probabilities: `choice` (pick one option), `noul` (yes/no), `score` (ordinal level).
// Docs: https://openrouter.ai/docs/guides/community/jev

/// Minimal JSON value so states can be built type-safely and stay `Sendable`.
public indirect enum JSONValue: Sendable, Hashable, Codable, ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral,
    ExpressibleByArrayLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(stringLiteral v: String) { self = .string(v) }
    public init(floatLiteral v: Double) { self = .number(v) }
    public init(integerLiteral v: Int) { self = .number(Double(v)) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    /// Pretty, key-sorted JSON text (for display / logging).
    public var prettyText: String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: e.encode(self), as: UTF8.self)) ?? ""
    }
}

public enum DecisionQuestion: Sendable, Hashable {
    /// Pick one option. `criteria` maps option key → description of when to pick it.
    case choice(instructions: String, criteria: [String: String])
    /// Yes/no. Returns P(true).
    case noul(instructions: String, whenTrue: String, whenFalse: String)
    /// Ordinal levels (max 10), lowest first.
    case score(instructions: String, levels: [String])

    /// Wire format of the question.
    public var json: JSONValue {
        switch self {
        case .choice(let i, let c):
            return .object(["type": "choice", "instructions": .string(i), "criteria": .object(c.mapValues { .string($0) })])
        case .noul(let i, let t, let f):
            return .object(["type": "noul", "instructions": .string(i), "criteria": .object(["true": .string(t), "false": .string(f)])])
        case .score(let i, let l):
            return .object(["type": "score", "instructions": .string(i), "criteria": .array(l.map { .string($0) })])
        }
    }
}

public enum DecisionAnswer: Sendable, Hashable, Codable {
    case choice(choice: String, confidence: Double?, probabilities: [String: Double])
    case noul(probability: Double)
    case score(score: Double, confidence: Double?, probabilities: [String: Double])

    public var choiceKey: String? { if case .choice(let c, _, _) = self { return c }; return nil }
    public var probabilities: [String: Double] {
        switch self {
        case .choice(_, _, let p), .score(_, _, let p): return p
        case .noul(let p): return ["true": p, "false": 1 - p]
        }
    }
}

public struct DecideResult: Sendable, Hashable, Codable {
    public var id: String?
    public var model: String
    public var provider: String?
    public var answers: [String: DecisionAnswer]
    /// promptTokens = input tokens; decision models bill input only.
    public var usage: APIUsage
    public var latency: Double
    /// Raw response body, for debugging / display.
    public var raw: String

    public init(id: String? = nil, model: String, provider: String? = nil, answers: [String: DecisionAnswer],
                usage: APIUsage = .init(), latency: Double = 0, raw: String = "") {
        self.id = id
        self.model = model
        self.provider = provider
        self.answers = answers
        self.usage = usage
        self.latency = latency
        self.raw = raw
    }
}

/// Anything that can answer System One questions (the OpenRouter client, or a test double).
public protocol DecisionProvider: Sendable {
    func decide(model: String, state: JSONValue, questions: [String: DecisionQuestion]) async throws -> DecideResult
}

extension OpenRouterClient: DecisionProvider {
    /// `POST /api/alpha/decisions` (falls back to `/api/v1/systemone`). Retries like `chat`.
    public func decide(model: String, state: JSONValue, questions: [String: DecisionQuestion]) async throws -> DecideResult {
        await acquire()
        defer { release() }

        let body: JSONValue = .object([
            "model": .string(model),
            "state": state,
            "questions": .object(questions.mapValues(\.json)),
        ])
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]  // byte-for-byte reproducible requests
        let payload = try enc.encode(body)
        let endpoints = [
            URL(string: "https://openrouter.ai/api/alpha/decisions")!,
            URL(string: "https://openrouter.ai/api/v1/systemone")!,
        ]
        let start = Date()
        var attempt = 0
        var endpoint = 0
        while true {
            do {
                let (data, resp) = try await session.data(for: request(url: endpoints[endpoint], body: payload))
                if let http = resp as? HTTPURLResponse, http.statusCode == 404 || http.statusCode == 405, endpoint + 1 < endpoints.count {
                    endpoint += 1
                    continue
                }
                try Self.check(resp, data)
                var r = try Self.parseDecision(data, model: model)
                r.latency = Date().timeIntervalSince(start)
                return r
            } catch let e as OpenRouterError where e.retryable && attempt < maxRetries {
                attempt += 1
            } catch let e as URLError where attempt < maxRetries && e.code != .cancelled {
                attempt += 1
            }
            try Task.checkCancellation()
            let backoff = min(30, pow(2, Double(attempt))) + Double.random(in: 0...1)
            try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
        }
    }

    static func parseDecision(_ data: Data, model: String) throws -> DecideResult {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = obj["answers"] as? [String: [String: Any]] else {
            throw OpenRouterError(status: nil, message: "Unexpected decisions response", retryable: true)
        }
        func probs(_ a: [String: Any]) -> [String: Double] {
            ((a["probabilities"] as? [String: Any]) ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
        }
        var parsed: [String: DecisionAnswer] = [:]
        for (key, a) in answers {
            let conf = (a["confidence"] as? NSNumber)?.doubleValue
            switch a["type"] as? String {
            case "choice":
                guard let c = a["choice"] as? String else { continue }
                parsed[key] = .choice(choice: c, confidence: conf, probabilities: probs(a))
            case "noul":
                parsed[key] = .noul(probability: (a["noul"] as? NSNumber)?.doubleValue ?? 0)
            case "score":
                parsed[key] = .score(score: (a["score"] as? NSNumber)?.doubleValue ?? 0, confidence: conf, probabilities: probs(a))
            default:
                continue
            }
        }
        var usage = APIUsage()
        if let u = obj["usage"] as? [String: Any] {
            usage.promptTokens = (u["input_tokens"] as? NSNumber)?.intValue ?? 0
            usage.completionTokens = (u["output_tokens"] as? NSNumber)?.intValue ?? 0
            usage.cost = (u["cost"] as? NSNumber)?.doubleValue ?? 0
        }
        return DecideResult(id: obj["id"] as? String, model: obj["model"] as? String ?? model, provider: obj["provider"] as? String,
                            answers: parsed, usage: usage, raw: String(decoding: data, as: UTF8.self))
    }
}

/// Decision models that work well for poker benchmarking, verified against the live catalog in the UI.
public enum DecisionRoster {
    public static let suggested: [String] = [
        "typesafe/jev-1.13",
        "perplexity/pplx-decider-v1.1-27b",
        "openai/gpt-6-luna-decisions",
        "liquid/d1",
        "cloudflare/clef",
        "cloudflare/clef-flash",
        "upstage/solar-decide",
        "inception/mercury-decide",
        "togethercomputer/tev1-4b-experimental",
        "jaredpalmer/kev-4b",
    ]
}
