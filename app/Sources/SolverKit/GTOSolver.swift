import CGTOCore
import Foundation

public struct SolverError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Thin JSON bridge to the Rust core.
enum Bridge {
    static func take(_ ptr: UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
        guard let ptr else { throw SolverError("solver returned no data") }
        defer { gto_string_free(ptr) }
        let data = Data(bytes: ptr, count: strlen(ptr))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SolverError("malformed solver response")
        }
        if obj["ok"] as? Bool != true {
            throw SolverError(obj["error"] as? String ?? "unknown solver error")
        }
        return obj
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: Any?) throws -> T {
        guard let value else { throw SolverError("missing field in solver response") }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}

/// Stateless helpers from the core.
public enum GTOCore {
    public static func parseRange(_ text: String) throws -> [Float] {
        let obj = try Bridge.take(gto_parse_range(text))
        guard let w = obj["weights"] as? [NSNumber], w.count == 1326 else { throw SolverError("bad range response") }
        return w.map(\.floatValue)
    }

    public static func estimate(_ config: SolverConfig) throws -> TreeEstimate {
        let obj = try Bridge.take(gto_estimate(try Bridge.json(config)))
        return try Bridge.decode(TreeEstimate.self, from: obj["estimate"])
    }

    public struct HandValue: Sendable, Comparable {
        public let value: UInt32
        public let category: String
        public static func < (a: HandValue, b: HandValue) -> Bool { a.value < b.value }
    }

    /// Evaluates 5-7 card hands; higher value wins.
    public static func evaluate(_ hands: [[Card]]) throws -> [HandValue] {
        let req = ["hands": hands.map { $0.compactText }]
        let data = try JSONSerialization.data(withJSONObject: req)
        let obj = try Bridge.take(gto_evaluate(String(decoding: data, as: UTF8.self)))
        guard let results = obj["results"] as? [[String: Any]] else { throw SolverError("bad evaluate response") }
        return results.map { HandValue(value: ($0["value"] as? NSNumber)?.uint32Value ?? 0, category: $0["category"] as? String ?? "") }
    }

    /// Monte-Carlo equity of `hand` against a weighted range text on a (partial) board.
    public static func equity(hand: [Card], board: [Card], range: String, samples: Int = 20_000) throws -> Double {
        let req: [String: Any] = ["hand": hand.compactText, "board": board.compactText, "range": range, "samples": samples]
        let data = try JSONSerialization.data(withJSONObject: req)
        let obj = try Bridge.take(gto_equity(String(decoding: data, as: UTF8.self)))
        return (obj["equity"] as? NSNumber)?.doubleValue ?? 0
    }
}

/// A postflop game being solved by the Rust Discounted-CFR engine.
///
/// `solve` blocks the calling thread; use `solveAsync` from UI code. `stop()`
/// may be called from any thread. Queries must not overlap with solving (they
/// will simply wait for the current solve call to return).
public final class GTOSolver: @unchecked Sendable {
    private let handle: OpaquePointer
    public let config: SolverConfig
    public let estimate: TreeEstimate

    public init(config: SolverConfig) throws {
        self.config = config
        var err: UnsafeMutablePointer<CChar>?
        let json = try Bridge.json(config)
        guard let h = gto_solver_create(json, &err) else {
            _ = try Bridge.take(err)
            throw SolverError("could not create solver")
        }
        handle = h
        do {
            let info = try Bridge.take(gto_solver_info(h))
            estimate = try Bridge.decode(TreeEstimate.self, from: info["estimate"])
        } catch {
            gto_solver_free(h)
            throw error
        }
    }

    deinit { gto_solver_free(handle) }

    private final class ProgressBox {
        let handler: (SolveProgress) -> Void
        init(_ h: @escaping (SolveProgress) -> Void) { handler = h }
    }

    /// Iterates until `maxIterations` total iterations or `targetExploitability` (% of pot).
    @discardableResult
    public func solve(maxIterations: Int, targetExploitability: Float, checkEvery: Int = 10,
                      progress: @escaping (SolveProgress) -> Void = { _ in }) throws -> SolveProgress {
        let box = Unmanaged.passRetained(ProgressBox(progress))
        defer { box.release() }
        let cb: gto_progress_cb = { ctx, it, ex, el in
            guard let ctx else { return }
            Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue()
                .handler(SolveProgress(iteration: it, exploitability: ex, elapsed: el))
        }
        let obj = try Bridge.take(gto_solver_solve(handle, UInt32(maxIterations), targetExploitability,
                                                   UInt32(max(1, checkEvery)), cb, box.toOpaque()))
        return try Bridge.decode(SolveProgress.self, from: obj["progress"])
    }

    /// Runs `solve` on a dedicated thread so the cooperative pool is never blocked.
    public func solveAsync(maxIterations: Int, targetExploitability: Float, checkEvery: Int = 10,
                           progress: @escaping @Sendable (SolveProgress) -> Void = { _ in }) async throws -> SolveProgress {
        try await withCheckedThrowingContinuation { cont in
            let t = Thread {
                do {
                    cont.resume(returning: try self.solve(maxIterations: maxIterations, targetExploitability: targetExploitability,
                                                          checkEvery: checkEvery, progress: progress))
                } catch {
                    cont.resume(throwing: error)
                }
            }
            t.stackSize = 16 << 20
            t.qualityOfService = .userInitiated
            t.start()
        }
    }

    public func stop() { gto_solver_stop(handle) }

    public func query(_ path: [PathStep] = []) throws -> NodeInfo {
        let data = try JSONSerialization.data(withJSONObject: path.map(\.json))
        let obj = try Bridge.take(gto_solver_query(handle, String(decoding: data, as: UTF8.self)))
        return try Bridge.decode(NodeInfo.self, from: obj["node"])
    }

    public func queryAsync(_ path: [PathStep] = []) async throws -> NodeInfo {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try self.query(path)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    public var progress: SolveProgress? {
        guard let info = try? Bridge.take(gto_solver_info(handle)) else { return nil }
        return try? Bridge.decode(SolveProgress.self, from: info["progress"])
    }
}
