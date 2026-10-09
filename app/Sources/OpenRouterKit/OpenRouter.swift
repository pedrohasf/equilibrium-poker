import Foundation
import Security

// MARK: - API key storage

/// Stores the OpenRouter API key in the login keychain. The `OPENROUTER_API_KEY`
/// environment variable takes precedence when set (handy for the CLI).
public enum APIKeyStore {
    private static let service = "app.equilibrium.openrouter"
    private static let account = "api-key"

    /// Lookup order: environment, a `.env` file (current directory or next to the app, walking up), keychain.
    public static var current: String? {
        if let env = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !env.isEmpty { return env }
        if let file = dotEnvValue { return file }
        return keychainValue
    }

    /// `OPENROUTER_API_KEY` from the nearest `.env`, searching up from the working directory and the app bundle.
    public static var dotEnvValue: String? {
        let starts = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath), Bundle.main.bundleURL]
        for start in starts {
            var dir = start
            for _ in 0..<6 {
                let file = dir.appendingPathComponent(".env")
                if let text = try? String(contentsOf: file, encoding: .utf8) {
                    for line in text.split(whereSeparator: \.isNewline) {
                        var l = line.trimmingCharacters(in: .whitespaces)
                        if l.hasPrefix("export ") { l = String(l.dropFirst(7)) }
                        guard l.hasPrefix("OPENROUTER_API_KEY=") else { continue }
                        let v = l.dropFirst("OPENROUTER_API_KEY=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                        if !v.isEmpty { return v }
                    }
                }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        return nil
    }

    public static var isFromEnvironment: Bool {
        !(ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? "").isEmpty || dotEnvValue != nil
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

public struct APIUsage: Codable, Hashable, Sendable {
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

    public static func + (a: APIUsage, b: APIUsage) -> APIUsage {
        APIUsage(promptTokens: a.promptTokens + b.promptTokens, completionTokens: a.completionTokens + b.completionTokens,
                  reasoningTokens: a.reasoningTokens + b.reasoningTokens, cost: a.cost + b.cost)
    }
}


public struct ModelInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var contextLength: Int?
    /// USD per token.
    public var promptPrice: Double?
    public var completionPrice: Double?
    public var created: Double?
    /// e.g. ["text"] or ["decisions"].
    public var outputModalities: [String]? = nil

    /// System One decision model (answers typed questions instead of generating text).
    public var isDecisionModel: Bool { outputModalities?.contains("decisions") ?? false }

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

/// Minimal OpenRouter client (model catalog + System One decisions) with retries and a concurrency cap.
public actor OpenRouterClient {
    public static let baseURL = URL(string: "https://openrouter.ai/api/v1")!

    private let apiKey: String
    let session: URLSession
    let maxRetries: Int
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

    func acquire() async {
        if inFlight < maxConcurrent {
            inFlight += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            inFlight -= 1
        }
    }

    private func request(_ path: String, body: Data? = nil) -> URLRequest {
        request(url: Self.baseURL.appendingPathComponent(path), body: body)
    }

    func request(url: URL, body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = body == nil ? "GET" : "POST"
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("https://github.com/equilibrium-poker", forHTTPHeaderField: "HTTP-Referer")
        r.setValue("Equilibrium Poker Lab", forHTTPHeaderField: "X-Title")
        r.httpBody = body
        return r
    }

    /// Text models plus System One decision models, de-duplicated.
    public func models() async throws -> [ModelInfo] {
        async let text = models(outputModality: nil)
        async let decisions = models(outputModality: "decisions")
        var seen = Set<String>()
        let decisionList = (try? await decisions) ?? []
        return (try await text + decisionList).filter { seen.insert($0.id).inserted }
    }

    /// Only the System One decision models (`output_modalities=decisions`).
    public func decisionModels() async throws -> [ModelInfo] {
        try await models(outputModality: "decisions")
    }

    private func models(outputModality: String?) async throws -> [ModelInfo] {
        var comps = URLComponents(url: Self.baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
        if let m = outputModality { comps.queryItems = [URLQueryItem(name: "output_modalities", value: m)] }
        let (data, resp) = try await session.data(for: request(url: comps.url!))
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
            let arch = m["architecture"] as? [String: Any]
            return ModelInfo(id: id, name: m["name"] as? String ?? id, contextLength: (m["context_length"] as? NSNumber)?.intValue,
                             promptPrice: price("prompt"), completionPrice: price("completion"),
                             created: (m["created"] as? NSNumber)?.doubleValue,
                             outputModalities: arch?["output_modalities"] as? [String])
        }
    }

    static func check(_ resp: URLResponse, _ data: Data) throws {
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
