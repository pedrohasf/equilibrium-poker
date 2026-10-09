import Foundation
import Observation
import SolverKit

/// What the matrix colours.
enum DisplayMode: String, CaseIterable, Identifiable {
    case strategy, ev, equity, range

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strategy: return "Strategy"
        case .ev: return "EV"
        case .equity: return "Equity"
        case .range: return "Range"
        }
    }
}

/// State of the whole solver workbench: configuration, the live solver,
/// progress history and the browsing position in the solved tree.
@Observable @MainActor
final class SolverSession {
    enum Phase: String, CaseIterable, Identifiable {
        case setup, solving, results
        var id: String { rawValue }
        var title: String {
            switch self {
            case .setup: return "Setup"
            case .solving: return "Solve"
            case .results: return "Results"
            }
        }
    }

    // MARK: Configuration

    var phase: Phase = .setup
    var scenarioID: String?
    var oopName = "OOP"
    var ipName = "IP"
    var config: SolverConfig {
        didSet { if config != oldValue { scheduleEstimate() } }
    }
    /// Parsed ranges [OOP, IP], kept in sync with `config.rangeOOP/IP`.
    private(set) var ranges: [HandRange] = [HandRange(), HandRange()]
    var targetExploitability: Double = 0.5
    var maxIterations: Int = 1000

    // MARK: Estimate

    private(set) var estimate: TreeEstimate?
    private(set) var estimateError: String?
    private(set) var isEstimating = false
    @ObservationIgnored private var estimateTask: Task<Void, Never>?

    // MARK: Solving

    @ObservationIgnored private(set) var solver: GTOSolver?
    private(set) var solvedConfig: SolverConfig?
    private(set) var solvedNames = ("OOP", "IP")
    private(set) var isPreparing = false
    private(set) var isSolving = false
    private(set) var progressHistory: [SolveProgress] = []
    private(set) var solveError: String?
    /// Wall-clock start of the current `solveAsync` run plus the solver's elapsed at that moment.
    private(set) var runStartedAt: Date?
    private(set) var runBaseElapsed: Double = 0
    private(set) var runTarget: Double = 0.5
    var continueIterations: Int = 500
    @ObservationIgnored private var solveTask: Task<Void, Never>?

    // MARK: Browsing

    private(set) var path: [PathStep] = []
    private(set) var node: NodeInfo?
    private(set) var pendingPath: [PathStep]?
    private(set) var queryError: String?
    private(set) var matrix: MatrixData?
    @ObservationIgnored private var cache: [[PathStep]: NodeInfo] = [:]
    @ObservationIgnored private var queryTask: Task<Void, Never>?

    var displayMode: DisplayMode = .strategy
    /// nil = follow the acting player.
    var viewedPlayerOverride: Int? {
        didSet { rebuildMatrix() }
    }
    var selectedClass: HandClass?

    init() {
        let s = Scenarios.all[0]
        config = SolverConfig(board: "Qs Jh 2h", rangeOOP: s.rangeOOP, rangeIP: s.rangeIP,
                              startingPot: s.pot, effectiveStack: s.stack, betSizes: .standard)
        applyScenario(s)
        scheduleEstimate()
    }

    // MARK: - Setup actions

    var scenario: Scenario? { scenarioID.flatMap(Scenarios.named) }

    func applyScenario(_ s: Scenario) {
        scenarioID = s.id
        oopName = s.oopName
        ipName = s.ipName
        config.startingPot = s.pot
        config.effectiveStack = s.stack
        _ = setRangeText(0, s.rangeOOP)
        _ = setRangeText(1, s.rangeIP)
    }

    func playerName(_ p: Int) -> String { p == 0 ? oopName : ipName }

    /// Parses and applies range text; returns an error message on failure.
    @discardableResult
    func setRangeText(_ p: Int, _ text: String) -> String? {
        do {
            let r = try HandRange(parsing: text)
            ranges[p] = r
            if p == 0 { config.rangeOOP = text } else { config.rangeIP = text }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func setRange(_ p: Int, _ range: HandRange) {
        ranges[p] = range
        let text = range.text
        if p == 0 { config.rangeOOP = text } else { config.rangeIP = text }
    }

    func rangeText(_ p: Int) -> String { p == 0 ? config.rangeOOP : config.rangeIP }

    var boardCards: [Card] { Card.parseList(config.board) ?? [] }

    func setBoard(_ cards: [Card]) { config.board = cards.text }

    func randomFlop() {
        setBoard(Array(Card.deck.shuffled().prefix(3)))
    }

    var boardIsValid: Bool { (3...5).contains(boardCards.count) && Card.parseList(config.board) != nil }

    var setupProblem: String? {
        if !boardIsValid { return "Pick a board of 3–5 cards." }
        if ranges[0].isEmpty { return "\(oopName) range is empty." }
        if ranges[1].isEmpty { return "\(ipName) range is empty." }
        if config.startingPot <= 0 { return "Pot must be positive." }
        if config.effectiveStack <= 0 { return "Stack must be positive." }
        return nil
    }

    static let physicalMemory = ProcessInfo.processInfo.physicalMemory
    static var memoryBudget: UInt64 { UInt64(Double(physicalMemory) * 0.85) }

    enum MemoryLevel { case ok, high, critical }

    var memoryLevel: MemoryLevel {
        guard let m = estimate?.memoryBytes else { return .ok }
        let f = Double(m) / Double(Self.physicalMemory)
        return f > 0.85 ? .critical : f > 0.5 ? .high : .ok
    }

    private func scheduleEstimate() {
        estimateTask?.cancel()
        guard setupProblem == nil else {
            estimate = nil
            estimateError = nil
            isEstimating = false
            return
        }
        let cfg = config
        isEstimating = true
        estimateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let result: Result<TreeEstimate, Error> = await Task.detached(priority: .userInitiated) {
                Result { try GTOCore.estimate(cfg) }
            }.value
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let e): self.estimate = e; self.estimateError = nil
            case .failure(let err): self.estimate = nil; self.estimateError = err.localizedDescription
            }
            self.isEstimating = false
        }
    }

    // MARK: - Solving

    var canSolve: Bool { setupProblem == nil && !isPreparing && !isSolving && memoryLevel != .critical }
    var canContinue: Bool { solver != nil && !isSolving && !isPreparing }
    var isBusy: Bool { isPreparing || isSolving }
    var latestProgress: SolveProgress? { progressHistory.last }

    private var checkEvery: Int {
        let n = (Card.parseList(solvedConfig?.board ?? config.board) ?? []).count
        return n >= 5 ? 25 : 10
    }

    func solve() {
        guard canSolve else { return }
        var cfg = config
        cfg.threads = max(0, UserDefaults.standard.integer(forKey: "solverThreads"))
        cfg.maxMemoryBytes = Self.memoryBudget
        // Release the previous tree before allocating a new (possibly multi-GB) one.
        queryTask?.cancel()
        solver = nil
        cache = [:]
        node = nil
        matrix = nil
        path = []
        pendingPath = nil
        selectedClass = nil
        progressHistory = []
        solveError = nil
        queryError = nil
        solvedConfig = cfg
        solvedNames = (oopName, ipName)
        phase = .solving
        isPreparing = true
        runTarget = targetExploitability
        let maxIt = maxIterations
        let target = targetExploitability
        solveTask = Task { [weak self] in
            let created: Result<GTOSolver, Error> = await Task.detached(priority: .userInitiated) {
                Result { try GTOSolver(config: cfg) }
            }.value
            guard let self else { return }
            self.isPreparing = false
            switch created {
            case .failure(let err):
                self.solveError = err.localizedDescription
                self.solvedConfig = nil
                return
            case .success(let s):
                if Task.isCancelled { self.phase = .setup; return }
                self.solver = s
                await self.run(s, maxIterations: maxIt, target: target)
            }
        }
    }

    /// Keeps iterating the current solver for `continueIterations` more iterations.
    func continueSolving() {
        guard canContinue, let s = solver else { return }
        let current = latestProgress
        var target = targetExploitability
        if let c = current, Double(c.exploitability) <= target {
            target = max(0.001, Double(c.exploitability) / 2)
            targetExploitability = (target * 1000).rounded() / 1000
        }
        let maxIt = Int(current?.iteration ?? 0) + max(1, continueIterations)
        phase = .solving
        solveError = nil
        solveTask = Task { [weak self] in
            await self?.run(s, maxIterations: maxIt, target: target)
        }
    }

    func stop() {
        if isPreparing {
            solveTask?.cancel()
        }
        solver?.stop()
    }

    private func run(_ s: GTOSolver, maxIterations: Int, target: Double) async {
        isSolving = true
        runTarget = target
        runBaseElapsed = latestProgress?.elapsed ?? 0
        runStartedAt = Date()
        defer {
            isSolving = false
            runStartedAt = nil
        }
        do {
            let final = try await s.solveAsync(maxIterations: maxIterations, targetExploitability: Float(target),
                                               checkEvery: checkEvery) { [weak self] p in
                Task { @MainActor in self?.record(p) }
            }
            record(final)
        } catch {
            solveError = error.localizedDescription
            return
        }
        // Strategies changed: drop cached nodes and reload where the user was.
        cache = [:]
        isSolving = false
        phase = .results
        navigate(to: path, force: true)
    }

    private func record(_ p: SolveProgress) {
        if let last = progressHistory.last, p.iteration <= last.iteration {
            if p.iteration == last.iteration { progressHistory[progressHistory.count - 1] = p }
            return
        }
        progressHistory.append(p)
    }

    /// Iterations per second over the most recent progress samples.
    var iterationsPerSecond: Double? {
        guard progressHistory.count >= 2 else {
            if let p = progressHistory.last, p.elapsed > 0 { return Double(p.iteration) / p.elapsed }
            return nil
        }
        let recent = progressHistory.suffix(6)
        guard let a = recent.first, let b = recent.last, b.elapsed > a.elapsed else { return nil }
        return Double(b.iteration - a.iteration) / (b.elapsed - a.elapsed)
    }

    // MARK: - Browsing

    var isLoadingNode: Bool { pendingPath != nil }

    /// Player whose data the matrix shows.
    var viewedPlayer: Int { viewedPlayerOverride ?? node?.player ?? 0 }

    func solvedName(_ p: Int) -> String { p == 0 ? solvedNames.0 : solvedNames.1 }

    func navigate(to newPath: [PathStep], force: Bool = false) {
        guard let solver, !isSolving else { return }
        queryError = nil
        if !force, let cached = cache[newPath] {
            queryTask?.cancel()
            pendingPath = nil
            show(cached, at: newPath)
            return
        }
        queryTask?.cancel()
        pendingPath = newPath
        queryTask = Task { [weak self] in
            do {
                let info = try await solver.queryAsync(newPath)
                guard !Task.isCancelled, let self, self.pendingPath == newPath else { return }
                self.cache[newPath] = info
                self.pendingPath = nil
                self.show(info, at: newPath)
            } catch {
                guard !Task.isCancelled, let self, self.pendingPath == newPath else { return }
                self.pendingPath = nil
                self.queryError = error.localizedDescription
                if newPath != [] && self.node == nil { self.navigate(to: []) }
            }
        }
    }

    private func show(_ info: NodeInfo, at newPath: [PathStep]) {
        path = newPath
        node = info
        if info.player != nil { viewedPlayerOverride = nil }
        rebuildMatrix()
    }

    private func rebuildMatrix() {
        guard let node else { matrix = nil; return }
        matrix = MatrixData(node: node, player: viewedPlayer)
    }

    func take(action i: Int) {
        guard let node, node.kind == .action, node.actions.indices.contains(i) else { return }
        navigate(to: path + [.action(i)])
    }

    func deal(_ card: String) {
        guard let node, node.kind == .chance, node.chanceCards.contains(card) else { return }
        navigate(to: path + [.card(card)])
    }

    func dealRandom() {
        guard let node, node.kind == .chance, let c = node.chanceCards.randomElement() else { return }
        deal(c)
    }

    func back() {
        guard !path.isEmpty else { return }
        navigate(to: Array(path.dropLast()))
    }

    func toRoot() { navigate(to: []) }

    func jump(toDepth d: Int) { navigate(to: Array(path.prefix(d))) }
}
