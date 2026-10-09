import Foundation
import LLMKit

// MARK: - Persistence

/// Suites live in `Storage.directory("suites")`, runs in `Storage.directory("runs")`, one JSON file each.
public enum BenchStore {
    /// Redirects storage (tests). nil = the app-support directories.
    nonisolated(unsafe) public static var rootOverride: URL?

    public static var suitesDirectory: URL { dir("suites") }
    public static var runsDirectory: URL { dir("runs") }

    private static func dir(_ sub: String) -> URL {
        guard let root = rootOverride else { return Storage.directory(sub) }
        let u = root.appendingPathComponent(sub, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    public static func url(suite id: String) -> URL { suitesDirectory.appendingPathComponent("\(id).json") }
    public static func url(run id: String) -> URL { runsDirectory.appendingPathComponent("\(id).json") }

    @discardableResult
    public static func save(_ suite: BenchmarkSuite, to url: URL? = nil) throws -> URL {
        let u = url ?? self.url(suite: suite.id)
        try Storage.encoder.encode(suite).write(to: u, options: .atomic)
        return u
    }

    public static func save(_ run: BenchmarkRun) throws {
        try Storage.encoder.encode(run).write(to: url(run: run.id), options: .atomic)
    }

    /// Loads by id, by id prefix, or from a file path.
    public static func loadSuite(_ idOrPath: String) throws -> BenchmarkSuite {
        let fm = FileManager.default
        var candidates = [URL(fileURLWithPath: (idOrPath as NSString).expandingTildeInPath), url(suite: idOrPath)]
        if let match = suites().first(where: { $0.id.hasPrefix(idOrPath) || $0.id.hasSuffix(idOrPath) }) {
            candidates.append(url(suite: match.id))
        }
        for u in candidates where fm.fileExists(atPath: u.path) && !u.hasDirectoryPath {
            return try Storage.decoder.decode(BenchmarkSuite.self, from: Data(contentsOf: u))
        }
        throw BenchError("No suite '\(idOrPath)'. Run `eqbench bench suites` to list them.")
    }

    /// All saved suites, newest first.
    public static func suites() -> [BenchmarkSuite] {
        let files = (try? FileManager.default.contentsOfDirectory(at: suitesDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Storage.decoder.decode(BenchmarkSuite.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public static func runs(suiteId: String? = nil) -> [BenchmarkRun] {
        let files = (try? FileManager.default.contentsOfDirectory(at: runsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Storage.decoder.decode(BenchmarkRun.self, from: Data(contentsOf: $0)) }
            .filter { suiteId == nil || $0.suiteId == suiteId }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public static func loadRun(id: String) -> BenchmarkRun? {
        try? Storage.decoder.decode(BenchmarkRun.self, from: Data(contentsOf: url(run: id)))
    }

    public static func deleteSuite(_ id: String, includingRuns: Bool = true) {
        try? FileManager.default.removeItem(at: url(suite: id))
        if includingRuns { for r in runs(suiteId: id) { deleteRun(r.id) } }
    }

    public static func deleteRun(_ id: String) {
        try? FileManager.default.removeItem(at: url(run: id))
    }
}

public struct BenchError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Running

public struct RunProgress: Sendable, Hashable {
    public var runId: String
    public var model: String
    public var label: String
    public var kind: PlayerKind
    public var done: Int
    public var total: Int
    public var invalid: Int
    /// Running GTO score (0–100) over answered decisions.
    public var score: Double
    /// Running mean EV loss, % of pot.
    public var evLossPot: Double
    public var cost: Double
    public var lastDecisionId: String?
    public var lastError: String?

    public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
}

/// Collects one run's results; saves periodically so cancelled/crashed runs can resume.
actor RunRecorder {
    private(set) var run: BenchmarkRun
    private let suite: BenchmarkSuite
    private let persist: Bool
    private var unsaved = 0
    private var scoreSum = 0.0
    private var lossSum = 0.0
    private var invalid = 0
    private var lastError: String?

    init(run: BenchmarkRun, suite: BenchmarkSuite, persist: Bool) {
        self.run = run
        self.suite = suite
        self.persist = persist
        let prior = Scoring.scores(run, suite: suite).map(\.1)
        scoreSum = prior.reduce(0) { $0 + $1.score * 100 }
        lossSum = prior.reduce(0) { $0 + $1.evLossPot }
        invalid = prior.filter { !$0.valid }.count
    }

    private func accumulate(_ s: DecisionScore) {
        scoreSum += s.score * 100
        lossSum += s.evLossPot
        if !s.valid { invalid += 1 }
    }

    func add(_ r: DecisionResult) -> RunProgress {
        run.results.removeAll { $0.decisionId == r.decisionId }
        run.results.append(r)
        run.updatedAt = Date()
        if let d = suite.decision(r.decisionId) { accumulate(Scoring.score(d, choice: r.choice)) }
        if let e = r.error { lastError = e }
        unsaved += 1
        if persist && unsaved >= 5 { flush() }
        return progress(last: r.decisionId)
    }

    func flush() {
        guard persist else { return }
        try? BenchStore.save(run)
        unsaved = 0
    }

    func progress(last: String? = nil) -> RunProgress {
        let done = run.results.count
        return RunProgress(runId: run.id, model: run.model, label: run.label, kind: run.kind, done: done, total: suite.decisions.count,
                           invalid: invalid, score: done == 0 ? 0 : scoreSum / Double(done),
                           evLossPot: done == 0 ? 0 : lossSum / Double(done), cost: run.totalCost,
                           lastDecisionId: last, lastError: lastError)
    }
}

public enum BenchmarkRunner {
    /// Runs every player on every (unanswered) decision of the suite with a global concurrency cap.
    /// Work is interleaved across players so all progress together. Cancelling the calling task
    /// stops promptly, saves partial runs and throws `CancellationError`; calling again resumes.
    @discardableResult
    public static func run(suite: BenchmarkSuite, players: [any DecisionMaker], concurrency: Int = 8, resume: Bool = true,
                           limit: Int? = nil, persist: Bool = true,
                           onProgress: @escaping @Sendable (RunProgress) -> Void = { _ in }) async throws -> [BenchmarkRun] {
        let decisions = Array(suite.decisions.prefix(limit ?? suite.decisions.count))
        var recorders: [RunRecorder] = []
        for p in players {
            let id = BenchmarkRun.makeId(suiteId: suite.id, model: p.id, options: p.options)
            var run = (resume ? BenchStore.loadRun(id: id) : nil)
                ?? BenchmarkRun(suiteId: suite.id, model: p.id, displayName: p.displayName, kind: p.kind, options: p.options)
            if !resume { run.results = [] }
            let rec = RunRecorder(run: run, suite: suite, persist: persist)
            recorders.append(rec)
            onProgress(await rec.progress())
        }

        // Interleaved job list: decision-major, player-minor.
        var jobs: [(Int, Decision)] = []
        var answered: [Set<String>] = []
        for rec in recorders { answered.append(await rec.run.answeredIds) }
        for d in decisions {
            for (pi, _) in players.enumerated() where !answered[pi].contains(d.id) { jobs.append((pi, d)) }
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var it = jobs.makeIterator()
                func launch() -> Bool {
                    guard let (pi, d) = it.next() else { return false }
                    let player = players[pi], rec = recorders[pi]
                    group.addTask {
                        try Task.checkCancellation()
                        let result: DecisionResult
                        do {
                            result = try await player.decide(d)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            result = DecisionResult(decisionId: d.id, choice: nil, error: error.localizedDescription)
                        }
                        // Keep answers that completed even if cancellation arrived meanwhile (they were paid for).
                        onProgress(await rec.add(result))
                    }
                    return true
                }
                for _ in 0..<max(1, concurrency) where launch() {}
                while try await group.next() != nil { _ = launch() }
            }
        } catch {
            for r in recorders { await r.flush() }
            throw error
        }
        var out: [BenchmarkRun] = []
        for r in recorders {
            await r.flush()
            out.append(await r.run)
        }
        return out
    }
}
