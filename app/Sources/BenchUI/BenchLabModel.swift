import BenchKit
import Foundation
import LLMKit
import Observation
import SolverKit

enum BenchTab: String, CaseIterable, Identifiable {
    case overview, run, leaderboard, decisions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Suite"
        case .run: return "Run"
        case .leaderboard: return "Leaderboard"
        case .decisions: return "Decisions"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "square.stack.3d.up"
        case .run: return "play.circle"
        case .leaderboard: return "trophy"
        case .decisions: return "rectangle.and.text.magnifyingglass"
        }
    }
}

/// The two kinds of API players the Run tab can pick from.
enum ModelGroup: String, CaseIterable, Identifiable {
    case decision, chat
    var id: String { rawValue }
    var title: String { self == .decision ? "Decision models" : "Chat LLMs" }
}

/// Persisted decision-model roster (kept in BenchUI; LLMKit's `ModelRoster` holds chat models).
enum DecisionModelRoster {
    private static let key = "decisionModelRoster"
    static var saved: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? DecisionRoster.suggested }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum CatalogState: Equatable {
    case idle, loading, loaded, failed(String)
}

/// State for the benchmark lab: suites, runs, the model catalog and live jobs.
@Observable
@MainActor
final class BenchLabModel {
    var suites: [BenchmarkSuite] = []
    var selectedSuiteId: String? {
        didSet { if oldValue != selectedSuiteId { reloadRuns() } }
    }
    var runs: [BenchmarkRun] = []
    private(set) var leaderboard: [ModelScore] = []
    var tab: BenchTab = .overview
    var selectedDecisionId: String?

    // Generation
    var showGenerateSheet = false
    var generating = false
    var generationProgress: GenerationProgress?
    var generationError: String?
    private var generationTask: Task<Void, Never>?

    // Models & options
    var catalog: [ModelInfo] = []
    var catalogState: CatalogState = .idle
    var roster: [String] = ModelRoster.saved {
        didSet { ModelRoster.saved = roster }
    }
    var decisionRoster: [String] = DecisionModelRoster.saved {
        didSet { DecisionModelRoster.saved = decisionRoster }
    }
    /// Which roster the Run tab shows; decision models are the benchmark's focus.
    var modelGroup: ModelGroup = .decision
    var selectedModels: Set<String> = []
    var reasoningEffort: String?
    var concurrency = 8
    var decisionLimit: Int?

    // Running
    var running = false
    var live: [String: RunProgress] = [:]
    var liveOrder: [String] = []
    var runError: String?
    private var runTask: Task<Void, Never>?
    private var lastRunReload = Date.distantPast

    var hasKey: Bool { !(APIKeyStore.current ?? "").isEmpty }

    var suite: BenchmarkSuite? { suites.first { $0.id == selectedSuiteId } }

    init() {
        reload()
    }

    // MARK: Loading

    func reload() {
        suites = BenchStore.suites()
        if selectedSuiteId == nil || suite == nil { selectedSuiteId = suites.first?.id }
        reloadRuns()
    }

    func reloadRuns() {
        guard let s = suite else {
            runs = []
            leaderboard = []
            return
        }
        runs = BenchStore.runs(suiteId: s.id)
        leaderboard = Scoring.leaderboard(suite: s, runs: runs)
    }

    func modelInfo(_ id: String) -> ModelInfo? { catalog.first { $0.id == id } }

    var decisionCatalog: [ModelInfo] { catalog.filter(\.isDecisionModel) }

    /// Decision model if the live catalog says so; otherwise if it's on the decision roster.
    func isDecisionModel(_ id: String) -> Bool {
        modelInfo(id)?.isDecisionModel ?? decisionRoster.contains(id)
    }

    /// Decision roster filtered by the live catalog once it's loaded (all entries before that).
    var visibleDecisionRoster: [String] {
        guard catalogState == .loaded, !decisionCatalog.isEmpty else { return decisionRoster }
        return decisionRoster.filter { modelInfo($0)?.isDecisionModel == true }
    }

    /// Roster entries hidden because the live catalog doesn't list them.
    var missingDecisionModels: [String] { decisionRoster.filter { !visibleDecisionRoster.contains($0) } }

    func roster(for group: ModelGroup) -> [String] { group == .decision ? visibleDecisionRoster : roster }

    func options(for id: String) -> ChatOptions? { isDecisionModel(id) ? nil : chatOptions }

    func runId(for id: String, suite: BenchmarkSuite) -> String {
        BenchmarkRun.makeId(suiteId: suite.id, model: id, options: options(for: id))
    }

    /// Selected ids in display order (decision models first).
    var selectedInOrder: [String] {
        (visibleDecisionRoster + roster.filter { !visibleDecisionRoster.contains($0) }).filter(selectedModels.contains)
    }

    var selectedChatCount: Int { selectedInOrder.filter { !isDecisionModel($0) }.count }

    func loadCatalog(force: Bool = false) async {
        guard hasKey else { return }
        if catalogState == .loading || (catalogState == .loaded && !force) { return }
        catalogState = .loading
        do {
            let client = try OpenRouterClient.fromStoredKey()
            catalog = try await client.models().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            catalogState = .loaded
        } catch {
            catalogState = .failed(error.localizedDescription)
        }
    }

    // MARK: Suites

    func generate(_ params: SuiteParameters, name: String?) {
        guard !generating else { return }
        generating = true
        generationError = nil
        generationProgress = GenerationProgress(solvesDone: 0, decisions: 0, target: params.decisions, elapsed: 0, lastSpot: nil)
        generationTask = Task {
            do {
                let suite = try await SuiteGenerator.generate(params, name: name) { p in
                    Task { @MainActor in self.generationProgress = p }
                }
                try BenchStore.save(suite)
                self.generating = false
                self.showGenerateSheet = false
                self.suites.insert(suite, at: 0)
                self.selectedSuiteId = suite.id
                self.tab = .overview
            } catch {
                self.generating = false
                self.generationError = error is CancellationError ? nil : error.localizedDescription
            }
        }
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        generating = false
    }

    func deleteSuite(_ id: String) {
        BenchStore.deleteSuite(id)
        if selectedSuiteId == id { selectedSuiteId = nil }
        reload()
    }

    func deleteRun(_ id: String) {
        BenchStore.deleteRun(id)
        reloadRuns()
    }

    // MARK: Runs

    func estimate(for model: String) -> CostEstimator.Estimate? {
        guard let s = suite else { return nil }
        let runId = runId(for: model, suite: s)
        let done = runs.first { $0.id == runId }?.answeredIds ?? []
        let todo = Array(s.decisions.prefix(decisionLimit ?? s.decisions.count)).filter { !done.contains($0.id) }
        let info = modelInfo(model)
        if isDecisionModel(model) { return CostEstimator.decisionEstimate(decisions: todo, promptPrice: info?.promptPrice) }
        return CostEstimator.estimate(decisions: todo, promptPrice: info?.promptPrice, completionPrice: info?.completionPrice,
                                      reasoningEffort: reasoningEffort)
    }

    var chatOptions: ChatOptions { ChatOptions(reasoningEffort: reasoningEffort) }

    func startModels() {
        guard let s = suite, !selectedModels.isEmpty else { return }
        do {
            let client = try OpenRouterClient.fromStoredKey(maxConcurrent: concurrency)
            let opts = chatOptions
            let players: [any DecisionMaker] = selectedInOrder.map { id -> any DecisionMaker in
                isDecisionModel(id) ? DecisionModelMaker(model: id, provider: client) : LLMDecisionMaker(model: id, client: client, options: opts)
            }
            start(players, suite: s)
        } catch {
            runError = error.localizedDescription
        }
    }

    func startBaselines() {
        guard let s = suite else { return }
        start(Baseline.allCases, suite: s)
    }

    private func start(_ players: [any DecisionMaker], suite: BenchmarkSuite) {
        guard !running else { return }
        running = true
        runError = nil
        live = [:]
        liveOrder = players.map { BenchmarkRun.makeId(suiteId: suite.id, model: $0.id, options: $0.options) }
        tab = players.allSatisfy({ $0.kind == .baseline }) ? tab : .run
        let limit = decisionLimit
        let concurrency = concurrency
        runTask = Task {
            do {
                _ = try await BenchmarkRunner.run(suite: suite, players: players, concurrency: concurrency, limit: limit) { p in
                    Task { @MainActor in self.apply(p) }
                }
            } catch {
                if !(error is CancellationError) { self.runError = error.localizedDescription }
            }
            self.running = false
            self.runTask = nil
            self.reloadRuns()
        }
    }

    private func apply(_ p: RunProgress) {
        live[p.runId] = p
        if Date().timeIntervalSince(lastRunReload) > 2 {
            lastRunReload = Date()
            reloadRuns()
        }
    }

    func cancelRun() {
        runTask?.cancel()
    }

    // MARK: Roster

    func addToRoster(_ id: String) {
        if modelInfo(id)?.isDecisionModel == true {
            if !decisionRoster.contains(id) { decisionRoster.append(id) }
        } else if !roster.contains(id) {
            roster.append(id)
        }
        selectedModels.insert(id)
    }

    func removeFromRoster(_ id: String) {
        roster.removeAll { $0 == id }
        decisionRoster.removeAll { $0 == id }
        selectedModels.remove(id)
    }

    func isOnRoster(_ id: String) -> Bool { roster.contains(id) || decisionRoster.contains(id) }
}
