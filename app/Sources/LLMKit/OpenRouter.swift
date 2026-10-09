import Foundation
import Security

// MARK: - API key storage

/// Stores the OpenRouter API key in the login keychain. The `OPENROUTER_API_KEY`
/// environment variable takes precedence when set (handy for the CLI).
public enum APIKeyStore {
    private static let service = "app.equilibrium.openrouter"
    private static let account = "api-key"

    public static var current: String? {
        if let env = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !env.isEmpty { return env }
        return keychainValue
    }

    public static var isFromEnvironment: Bool {
        !(ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? "").isEmpty
    }

    public static var keychainValue: String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func save(_ key: String) -> Bool {
        delete()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(trimmed.utf8),
        ]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    public static func delete() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Models

public struct ChatMessage: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }
    public var role: Role
    public var content: String

    public init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ s: String) -> ChatMessage { .init(.system, s) }
    public static func user(_ s: String) -> ChatMessage { .init(.user, s) }
    public static func assistant(_ s: String) -> ChatMessage { .init(.assistant, s) }
}

public struct ChatOptions: Codable, Hashable, Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    /// OpenRouter unified reasoning effort: "minimal", "low", "medium", "high" (nil = provider default).
    public var reasoningEffort: String?
    /// Ask the provider for a JSON object response when supported.
    public var jsonMode: Bool

    public init(temperature: Double? = nil, maxTokens: Int? = nil, reasoningEffort: String? = nil, jsonMode: Bool = false) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.reasoningEffort = reasoningEffort
        self.jsonMode = jsonMode
    }
}

public struct ChatUsage: Codable, Hashable, Sendable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var reasoningTokens: Int
    /// USD as reported by OpenRouter (0 if unavailable).
    public var cost: Double

    public init(promptTokens: Int = 0, completionTokens: Int = 0, reasoningTokens: Int = 0, cost: Double = 0) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.reasoningTokens = reasoningTokens
        self.cost = cost
    }

    public static func + (a: ChatUsage, b: ChatUsage) -> ChatUsage {
        ChatUsage(promptTokens: a.promptTokens + b.promptTokens, completionTokens: a.completionTokens + b.completionTokens,
                  reasoningTokens: a.reasoningTokens + b.reasoningTokens, cost: a.cost + b.cost)
    }
}

public struct ChatResult: Codable, Hashable, Sendable {
    public var model: String
    public var content: String
    /// Provider-exposed reasoning text, if any.
    public var reasoning: String?
    public var usage: ChatUsage
    /// Wall-clock seconds for the request (including retries).
    public var latency: Double
    public var finishReason: String?
}

public struct ModelInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var contextLength: Int?
    /// USD per token.
    public var promptPrice: Double?
    public var completionPrice: Double?
    public var created: Double?

    public var provider: String { String(id.split(separator: "/").first ?? "") }

    /// USD per million tokens, for display.
    public var promptPricePerM: Double? { promptPrice.map { $0 * 1_000_000 } }
    public var completionPricePerM: Double? { completionPrice.map { $0 * 1_000_000 } }
}

public struct OpenRouterError: LocalizedError, Sendable {
    public var status: Int?
    public var message: String
    public var retryable: Bool
    public var errorDescription: String? { status.map { "OpenRouter \($0): \(message)" } ?? message }
}

// MARK: - Client

/// Minimal OpenRouter chat-completions client with retries and a concurrency cap.
public actor OpenRouterClient {
    public static let baseURL = URL(string: "https://openrouter.ai/api/v1")!

    private let apiKey: String
    private let session: URLSession
    private let maxRetries: Int
    private var inFlight = 0
    private let maxConcurrent: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(apiKey: String, maxConcurrent: Int = 8, maxRetries: Int = 4, timeout: TimeInterval = 180) {
        self.apiKey = apiKey
        self.maxConcurrent = max(1, maxConcurrent)
        self.maxRetries = maxRetries
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 2
        cfg.httpMaximumConnectionsPerHost = max(4, maxConcurrent)
        session = URLSession(configuration: cfg)
    }

    /// Builds a client from the stored key, or throws a helpful error.
    public static func fromStoredKey(maxConcurrent: Int = 8) throws -> OpenRouterClient {
        guard let key = APIKeyStore.current, !key.isEmpty else {
            throw OpenRouterError(status: nil, message: "No OpenRouter API key. Add one in Settings or set OPENROUTER_API_KEY.", retryable: false)
        }
        return OpenRouterClient(apiKey: key, maxConcurrent: maxConcurrent)
    }

    private func acquire() async {
        if inFlight < maxConcurrent {
            inFlight += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            inFlight -= 1
        }
    }

    private func request(_ path: String, body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        r.httpMethod = body == nil ? "GET" : "POST"
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("https://github.com/equilibrium-poker", forHTTPHeaderField: "HTTP-Referer")
        r.setValue("Equilibrium Poker Lab", forHTTPHeaderField: "X-Title")
        r.httpBody = body
        return r
    }

    public func models() async throws -> [ModelInfo] {
        let (data, resp) = try await session.data(for: request("models"))
        try Self.check(resp, data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else {
            throw OpenRouterError(status: nil, message: "Unexpected /models response", retryable: false)
        }
        return list.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let pricing = m["pricing"] as? [String: Any]
            func price(_ k: String) -> Double? {
                if let s = pricing?[k] as? String { return Double(s) }
                return (pricing?[k] as? NSNumber)?.doubleValue
            }
            return ModelInfo(id: id, name: m["name"] as? String ?? id, contextLength: (m["context_length"] as? NSNumber)?.intValue,
                             promptPrice: price("prompt"), completionPrice: price("completion"),
                             created: (m["created"] as? NSNumber)?.doubleValue)
        }
    }

    public func chat(model: String, messages: [ChatMessage], options: ChatOptions = .init()) async throws -> ChatResult {
        await acquire()
        defer { release() }

        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "usage": ["include": true],
        ]
        if let t = options.temperature { body["temperature"] = t }
        if let m = options.maxTokens { body["max_tokens"] = m }
        if let e = options.reasoningEffort { body["reasoning"] = ["effort": e] }
        if options.jsonMode { body["response_format"] = ["type": "json_object"] }
        let payload = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        var attempt = 0
        while true {
            do {
                let (data, resp) = try await session.data(for: request("chat/completions", body: payload))
                try Self.check(resp, data)
                var result = try Self.parseChat(data, model: model)
                result.latency = Date().timeIntervalSince(start)
                return result
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

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        if (200..<300).contains(http.statusCode) {
            // OpenRouter can return 200 with an error body for upstream failures.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let err = obj["error"] as? [String: Any] {
                let code = (err["code"] as? NSNumber)?.intValue
                throw OpenRouterError(status: code, message: err["message"] as? String ?? "upstream error",
                                      retryable: code.map { $0 == 429 || $0 >= 500 } ?? true)
            }
            return
        }
        var message = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any], let m = err["message"] as? String {
            message = m
        }
        let retryable = http.statusCode == 429 || http.statusCode == 408 || http.statusCode >= 500
        throw OpenRouterError(status: http.statusCode, message: message, retryable: retryable)
    }

    private static func parseChat(_ data: Data, model: String) throws -> ChatResult {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]], let first = choices.first else {
            throw OpenRouterError(status: nil, message: "Empty completion", retryable: true)
        }
        let msg = first["message"] as? [String: Any]
        let content = msg?["content"] as? String ?? ""
        let reasoning = msg?["reasoning"] as? String
        var usage = ChatUsage()
        if let u = obj["usage"] as? [String: Any] {
            usage.promptTokens = (u["prompt_tokens"] as? NSNumber)?.intValue ?? 0
            usage.completionTokens = (u["completion_tokens"] as? NSNumber)?.intValue ?? 0
            usage.cost = (u["cost"] as? NSNumber)?.doubleValue ?? 0
            if let d = u["completion_tokens_details"] as? [String: Any] {
                usage.reasoningTokens = (d["reasoning_tokens"] as? NSNumber)?.intValue ?? 0
            }
        }
        if content.isEmpty && (reasoning ?? "").isEmpty {
            throw OpenRouterError(status: nil, message: "Model returned an empty message", retryable: true)
        }
        return ChatResult(model: obj["model"] as? String ?? model, content: content, reasoning: reasoning, usage: usage,
                          latency: 0, finishReason: first["finish_reason"] as? String)
    }
}

// MARK: - Shared helpers

public enum LLMParsing {
    /// Extracts the last JSON object embedded in free text (handles ```json fences).
    public static func lastJSONObject(in text: String) -> [String: Any]? {
        let chars = Array(text)
        var end = chars.count - 1
        while end >= 0 {
            guard let close = (0...end).last(where: { chars[$0] == "}" }) else { return nil }
            var depth = 0
            var i = close
            while i >= 0 {
                if chars[i] == "}" { depth += 1 }
                if chars[i] == "{" {
                    depth -= 1
                    if depth == 0 {
                        let s = String(chars[i...close])
                        if let d = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                            return obj
                        }
                        break
                    }
                }
                i -= 1
            }
            end = close - 1
        }
        return nil
    }
}

/// Persisted list of models the user likes to benchmark.
public enum ModelRoster {
    /// Reasonable defaults; the UI validates them against the live /models catalog.
    public static let suggested: [String] = [
        "openai/gpt-5",
        "anthropic/claude-sonnet-4.5",
        "google/gemini-2.5-pro",
        "x-ai/grok-4",
        "deepseek/deepseek-chat-v3.1",
        "qwen/qwen3-235b-a22b-2507",
        "meta-llama/llama-4-maverick",
        "openai/gpt-5-mini",
    ]

    private static let key = "modelRoster"

    public static var saved: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? suggested }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Where benchmark artefacts live: ~/Library/Application Support/Equilibrium/<sub>.
public enum Storage {
    public static func directory(_ sub: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Equilibrium", isDirectory: true)
            .appendingPathComponent(sub, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
