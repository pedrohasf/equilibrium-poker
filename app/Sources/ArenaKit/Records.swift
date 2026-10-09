import Foundation
import LLMKit
import SolverKit

public struct MatchConfig: Codable, Hashable, Sendable {
    /// Number of distinct deals. In duplicate mode each deal is played twice (2N hands).
    public var deals: Int
    public var seed: UInt64
    /// Deals played in parallel.
    public var concurrency: Int
    public var duplicate: Bool
    public var stackBB: Double
    /// Give LLM players a running summary of the match (opponent stats) in the prompt.
    public var opponentStats: Bool

    public init(deals: Int = 50, seed: UInt64 = 1, concurrency: Int = 4, duplicate: Bool = true, stackBB: Double = 100, opponentStats: Bool = false) {
        self.deals = deals
        self.seed = seed
        self.concurrency = concurrency
        self.duplicate = duplicate
        self.stackBB = stackBB
        self.opponentStats = opponentStats
    }

    public var totalHands: Int { duplicate ? deals * 2 : deals }

    public var handConfig: HandConfig {
        let s = Chips.from(bb: stackBB)
        return HandConfig(smallBlind: 50, bigBlind: 100, stacks: [s, s])
    }
}

/// A finished hand with everything needed to replay it.
public struct HandRecord: Codable, Hashable, Sendable, Identifiable {
    /// 1-based hand number within the match (deal * 2 + replica + 1 in duplicate mode).
    public var number: Int
    /// 0-based deal index.
    public var deal: Int
    /// 0: player A has the button; 1: seats swapped (same cards to the same seat).
    public var replica: Int
    /// Player index (0 = A, 1 = B) sitting in each seat (seat 0 = button).
    public var seatPlayers: [Int]
    /// Hole cards by seat, e.g. "AsKd".
    public var hole: [String]
    /// The full five-card runout (only `boardCount` were shown).
    public var runout: String
    public var boardCount: Int
    public var config: HandConfig
    public var actions: [ActionRecord]
    public var result: HandResult
    public var duration: Double

    public var id: Int { number }

    public var holeCards: [[Card]] { hole.map { Card.parseList($0) ?? [] } }
    public var runoutCards: [Card] { Card.parseList(runout) ?? [] }
    public var board: [Card] { Array(runoutCards.prefix(boardCount)) }

    public func seat(of player: Int) -> Int { seatPlayers.firstIndex(of: player) ?? player }
    /// Net big blinds for player 0 (A) or 1 (B).
    public func net(_ player: Int) -> Double { Chips.bb(result.net[seat(of: player)]) }
    public func evNet(_ player: Int) -> Double { result.evNet[seat(of: player)] / Double(Chips.perBB) }

    public init(number: Int, deal: Int, replica: Int, seatPlayers: [Int], state: HandState, duration: Double) {
        self.number = number
        self.deal = deal
        self.replica = replica
        self.seatPlayers = seatPlayers
        hole = state.hole.map(\.compactText)
        runout = state.runout.compactText
        boardCount = state.boardCount
        config = state.config
        actions = state.actions
        result = state.result!
        self.duration = duration
    }

    /// Rebuilds the initial state of the hand.
    public var initialState: HandState { HandState(config: config, hole: holeCards, runout: runoutCards) }
}

public enum MatchStatus: String, Codable, Sendable { case running, completed, cancelled, failed }

public struct MatchRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var finishedAt: Date?
    public var status: MatchStatus
    public var config: MatchConfig
    /// Player A and player B.
    public var players: [PlayerSpec]
    public var hands: [HandRecord]
    public var summary: MatchSummary?
    public var error: String?

    public init(id: String = MatchRecord.newID(), config: MatchConfig, players: [PlayerSpec]) {
        self.id = id
        createdAt = Date()
        status = .running
        self.config = config
        self.players = players
        hands = []
    }

    public static func newID(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = String(UInt32.random(in: 0..<UInt32.max), radix: 16)
        return "\(f.string(from: date))-\(suffix.prefix(4))"
    }

    public var title: String { "\(players[0].displayName) vs \(players[1].displayName)" }

    public mutating func recomputeSummary() { summary = MatchStats.summarize(self) }
}

/// Saves matches as JSON under Application Support/Equilibrium/arena.
public enum MatchStore {
    public static var directory: URL { Storage.directory("arena") }

    public static func url(for id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    public static func save(_ m: MatchRecord) throws {
        try Storage.encoder.encode(m).write(to: url(for: m.id), options: .atomic)
    }

    public static func load(_ id: String) throws -> MatchRecord {
        try Storage.decoder.decode(MatchRecord.self, from: Data(contentsOf: url(for: id)))
    }

    /// Finds a match by exact id or unique prefix.
    public static func find(_ prefix: String) throws -> MatchRecord {
        if FileManager.default.fileExists(atPath: url(for: prefix).path) { return try load(prefix) }
        let ids = listIDs().filter { $0.hasPrefix(prefix) }
        guard ids.count == 1 else {
            throw EngineError(ids.isEmpty ? "no match with id '\(prefix)'" : "ambiguous match id '\(prefix)' (\(ids.count) matches)")
        }
        return try load(ids[0])
    }

    public static func listIDs() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    /// All saved matches, newest first. Unreadable files are skipped.
    public static func all() -> [MatchRecord] {
        listIDs().compactMap { try? load($0) }.sorted { $0.createdAt > $1.createdAt }
    }

    public static func delete(_ id: String) throws {
        try FileManager.default.removeItem(at: url(for: id))
    }
}
