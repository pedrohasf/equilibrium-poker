import Foundation

/// A preflop scenario that defines the postflop starting point (100bb, 6-max, 2.5x opens).
/// Ranges are simplified approximations of common equilibrium charts.
public struct Scenario: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public var oopName: String
    public var ipName: String
    public var rangeOOP: String
    public var rangeIP: String
    /// Pot at the start of the flop, in big blinds.
    public var pot: Double
    /// Effective remaining stack at the start of the flop, in big blinds.
    public var stack: Double
    public var summary: String
    /// Game format this spot belongs to (nil in older saved data = cash).
    public var formatId: String?

    public var format: GameFormat { formatId.flatMap(GameFormat.init(rawValue:)) ?? .cash }

    public init(id: String, name: String, oopName: String, ipName: String, rangeOOP: String, rangeIP: String,
                pot: Double, stack: Double, summary: String, format: GameFormat = .cash) {
        self.formatId = format.rawValue
        self.id = id
        self.name = name
        self.oopName = oopName
        self.ipName = ipName
        self.rangeOOP = rangeOOP
        self.rangeIP = rangeIP
        self.pot = pot
        self.stack = stack
        self.summary = summary
    }

    public var spr: Double { stack / pot }
}

/// Poker formats, distinguished postflop by stack depth, antes and the preflop ranges that see a flop.
/// Chip-EV only: tournament payout pressure (ICM) is not modelled.
public enum GameFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case cash, mtt40, mtt20, spin

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cash: return "Cash game · 100bb"
        case .mtt40: return "Tournament · 40bb (ante)"
        case .mtt20: return "Tournament · 20bb (ante)"
        case .spin: return "Spin & Go · 15–25bb"
        }
    }

    public var shortTitle: String {
        switch self {
        case .cash: return "Cash 100bb"
        case .mtt40: return "MTT 40bb"
        case .mtt20: return "MTT 20bb"
        case .spin: return "Spin & Go"
        }
    }

    public var summary: String {
        switch self {
        case .cash: return "Deep-stacked cash games: 6-max, 100bb, 2.5x opens, no ante."
        case .mtt40: return "Mid-stage tournament: 40bb effective, 2.2x opens, 1bb big-blind ante. Chip EV (no ICM)."
        case .mtt20: return "Late-stage tournament: 20bb effective, 2x opens, 1bb big-blind ante, low SPR. Chip EV (no ICM)."
        case .spin: return "Hyper-turbo 3-max Spin & Go: 25bb 3-handed and 15bb heads-up, min-raises, very wide ranges. Chip EV."
        }
    }
}

public enum RangeLibrary {
    public static let btnOpen = "22+,A2s+,K2s+,Q2s+,J4s+,T6s+,96s+,85s+,75s+,64s+,54s,A2o+,K8o+,Q9o+,J9o+,T9o,98o"
    public static let coOpen = "22+,A2s+,K6s+,Q8s+,J8s+,T8s+,97s+,87s,76s,65s,ATo+,KTo+,QTo+,JTo"
    public static let utgOpen = "33+,A2s+,K9s+,QTs+,JTs,T9s,98s,AJo+,KQo"
    public static let sbOpen = "22+,A2s+,K2s+,Q4s+,J6s+,T6s+,96s+,85s+,75s+,64s+,54s,A2o+,K8o+,Q9o+,J9o+,T9o"

    public static let bbCallVsBtn = "22-99,TT:0.6,JJ:0.3,A2s-A9s,ATs:0.8,AJs:0.6,AQs:0.4,K2s-KJs,KQs:0.6,Q2s-QJs,J4s-JTs,T6s-T9s,96s+,85s+,74s+,63s+,53s+,43s,A2o-AJo,AQo:0.6,K7o-KQo,Q8o+,J8o+,T8o+,97o+,87o,76o,65o"
    public static let bbCallVsCo = "22-TT,JJ:0.4,A2s-AJs,AQs:0.5,K5s-KJs,KQs:0.5,Q7s-QJs,J7s-JTs,T7s-T9s,96s+,86s+,75s+,64s+,54s,A9o-AJo,AQo:0.5,KTo-KQo,QTo+,JTo"
    public static let bbCallVsUtg = "22-TT,JJ:0.5,A2s-AJs,AQs:0.6,K8s-KQs,Q9s+,J9s+,T8s+,97s+,86s+,76s,65s,54s,AJo-AQo,KJo+,QJo"
    public static let bbCallVsSb = "22-JJ,QQ:0.3,A2s-AQs,K2s-KQs,Q4s+,J6s+,T6s+,96s+,85s+,74s+,64s+,53s+,A2o-AJo,AQo:0.5,K8o+,Q9o+,J9o+,T8o+,98o"

    public static let bb3betVsBtn = "QQ+,JJ:0.5,TT:0.3,AKs,AQs:0.5,A5s-A3s,K9s:0.5,QTs:0.3,AKo,AJo:0.3,KQo:0.4,76s:0.3,65s:0.3"
    public static let btnCallVs3bet = "22-JJ,QQ:0.3,A2s-AQs,AKs:0.3,K9s+,Q9s+,J9s+,T8s+,98s,87s,76s,65s,AJo-AQo,AKo:0.4,KJo+"
    public static let btn3betVsCo = "TT+,99:0.5,AJs+,KQs,KJs:0.5,A5s-A3s,76s:0.3,65s:0.3,AQo+"
    public static let coCallVs3bet = "77-QQ,ATs-AQs,A5s-A4s,KTs+,QTs+,JTs,T9s,AQo,KQo:0.5"
}

public enum TournamentRanges {
    // 40bb, 1bb BB ante, 2.2x opens
    public static let btnOpen40 = "22+,A2s+,K2s+,Q2s+,J3s+,T5s+,95s+,85s+,74s+,64s+,53s+,43s,A2o+,K5o+,Q8o+,J8o+,T8o+,98o"
    public static let bbCall40 = "22-99,TT:0.5,A2s-AJs,AQs:0.4,K2s-KQs,Q2s-QJs,J2s-JTs,T3s+,93s+,84s+,74s+,63s+,52s+,42s+,32s,A2o-AJo,AQo:0.5,K4o-KQo,Q6o+,J7o+,T7o+,97o+,86o+,76o,65o"
    public static let bb3bet40 = "JJ+,TT:0.5,AQs+,AJs:0.5,A5s-A2s:0.5,KQs:0.5,AKo,AQo:0.5,K9s:0.3,76s:0.3"
    public static let btnCall3bet40 = "22-TT,JJ:0.4,A6s-AJs,AQs:0.6,K9s+,Q9s+,J9s+,T8s+,98s,87s,76s,ATo-AJo,KJo+:0.6"
    // 20bb, 1bb BB ante, 2x opens (non-jam range)
    public static let btnOpen20 = "22+,A2s+,K2s+,Q4s+,J6s+,T6s+,96s+,85s+,75s+,64s+,54s,A2o+,K8o+,Q9o+,J9o+,T9o"
    public static let bbCall20 = "22-88,99:0.6,A2s-ATs,K2s-KJs,Q4s-QJs,J6s-JTs,T6s+,96s+,85s+,74s+,64s+,53s+,A2o-ATo,K7o-KJo,Q8o+,J8o+,T8o+,98o"
    public static let sbOpen20 = "22+,A2s+,K2s+,Q2s+,J4s+,T6s+,96s+,85s+,75s+,64s+,54s,A2o+,K7o+,Q9o+,J9o+,T9o"
    public static let bbCallVsSb20 = "22-88,A2s-ATs,K2s-KJs,Q2s-QJs,J5s+,T6s+,96s+,85s+,74s+,63s+,53s+,A2o-ATo,K5o-KJo,Q8o+,J8o+,T8o+,98o"
    // Spin & Go
    public static let spinBtnOpen25 = "22+,A2s+,K2s+,Q2s+,J4s+,T6s+,96s+,85s+,75s+,64s+,54s,A2o+,K7o+,Q9o+,J9o+,T9o"
    public static let spinBbCall25 = "22-99,A2s-AJs,K2s-KQs,Q2s-QJs,J3s+,T5s+,95s+,84s+,74s+,63s+,53s+,43s,A2o-AJo,K4o-KQo,Q7o+,J7o+,T7o+,97o+,87o"
    public static let spinSbOpen15 = "22+,A2s+,K2s+,Q2s+,J2s+,T4s+,95s+,85s+,74s+,64s+,53s+,43s,A2o+,K2o+,Q5o+,J7o+,T7o+,97o+,87o"
    public static let spinBbCall15 = "22-99,A2s-AJs,K2s-KQs,Q2s-QJs,J2s+,T2s+,94s+,84s+,74s+,63s+,53s+,43s,A2o-ATo,K2o-KQo,Q4o+,J6o+,T6o+,96o+,86o+,76o,65o"
}

public enum Scenarios {
    /// Cash-game scenarios (the default benchmark/solver set).
    public static var all: [Scenario] { cash }

    /// Every scenario across all formats.
    public static var every: [Scenario] { cash + tournament }

    public static func forFormat(_ f: GameFormat) -> [Scenario] { every.filter { $0.format == f } }

    public static let tournament: [Scenario] = [
        Scenario(id: "mtt40-btn-bb-srp", name: "MTT 40bb · BTN vs BB", oopName: "BB", ipName: "BTN",
                 rangeOOP: TournamentRanges.bbCall40, rangeIP: TournamentRanges.btnOpen40, pot: 5.9, stack: 37.8,
                 summary: "40bb, 1bb BB ante. BTN opens 2.2bb, BB calls.", format: .mtt40),
        Scenario(id: "mtt40-bb-btn-3bp", name: "MTT 40bb · BB vs BTN 3-bet", oopName: "BB", ipName: "BTN",
                 rangeOOP: TournamentRanges.bb3bet40, rangeIP: TournamentRanges.btnCall3bet40, pot: 19.5, stack: 31,
                 summary: "40bb, 1bb BB ante. BTN opens 2.2bb, BB 3-bets to 9bb, BTN calls.", format: .mtt40),
        Scenario(id: "mtt20-btn-bb-srp", name: "MTT 20bb · BTN vs BB", oopName: "BB", ipName: "BTN",
                 rangeOOP: TournamentRanges.bbCall20, rangeIP: TournamentRanges.btnOpen20, pot: 5.5, stack: 18,
                 summary: "20bb, 1bb BB ante. BTN min-raises to 2bb, BB calls.", format: .mtt20),
        Scenario(id: "mtt20-sb-bb-srp", name: "MTT 20bb · SB vs BB", oopName: "SB", ipName: "BB",
                 rangeOOP: TournamentRanges.sbOpen20, rangeIP: TournamentRanges.bbCallVsSb20, pot: 5, stack: 18,
                 summary: "20bb, 1bb BB ante. SB min-raises to 2bb, BB calls.", format: .mtt20),
        Scenario(id: "spin25-btn-bb-srp", name: "Spin & Go 25bb · BTN vs BB", oopName: "BB", ipName: "BTN",
                 rangeOOP: TournamentRanges.spinBbCall25, rangeIP: TournamentRanges.spinBtnOpen25, pot: 4.5, stack: 23,
                 summary: "3-handed, 25bb. BTN min-raises to 2bb, SB folds, BB calls.", format: .spin),
        Scenario(id: "spin15-hu-sb-bb", name: "Spin & Go 15bb · heads-up", oopName: "BB", ipName: "SB",
                 rangeOOP: TournamentRanges.spinBbCall15, rangeIP: TournamentRanges.spinSbOpen15, pot: 4, stack: 13,
                 summary: "Heads-up, 15bb. SB (button) min-raises to 2bb, BB calls.", format: .spin),
    ]

    public static let cash: [Scenario] = [
        Scenario(id: "btn-bb-srp", name: "BTN vs BB · single raised", oopName: "BB", ipName: "BTN",
                 rangeOOP: RangeLibrary.bbCallVsBtn, rangeIP: RangeLibrary.btnOpen, pot: 5.5, stack: 97.5,
                 summary: "BTN opens 2.5bb, BB calls."),
        Scenario(id: "co-bb-srp", name: "CO vs BB · single raised", oopName: "BB", ipName: "CO",
                 rangeOOP: RangeLibrary.bbCallVsCo, rangeIP: RangeLibrary.coOpen, pot: 5.5, stack: 97.5,
                 summary: "CO opens 2.5bb, BB calls."),
        Scenario(id: "utg-bb-srp", name: "UTG vs BB · single raised", oopName: "BB", ipName: "UTG",
                 rangeOOP: RangeLibrary.bbCallVsUtg, rangeIP: RangeLibrary.utgOpen, pot: 5.5, stack: 97.5,
                 summary: "UTG opens 2.5bb, BB calls."),
        Scenario(id: "sb-bb-srp", name: "SB vs BB · single raised", oopName: "SB", ipName: "BB",
                 rangeOOP: RangeLibrary.sbOpen, rangeIP: RangeLibrary.bbCallVsSb, pot: 6, stack: 97,
                 summary: "SB opens 3bb, BB calls. SB is out of position."),
        Scenario(id: "btn-bb-3bp", name: "BB vs BTN · 3-bet pot", oopName: "BB", ipName: "BTN",
                 rangeOOP: RangeLibrary.bb3betVsBtn, rangeIP: RangeLibrary.btnCallVs3bet, pot: 22.5, stack: 89,
                 summary: "BTN opens 2.5bb, BB 3-bets to 11bb, BTN calls."),
        Scenario(id: "co-btn-3bp", name: "CO vs BTN · 3-bet pot", oopName: "CO", ipName: "BTN",
                 rangeOOP: RangeLibrary.coCallVs3bet, rangeIP: RangeLibrary.btn3betVsCo, pot: 16.5, stack: 92.5,
                 summary: "CO opens 2.5bb, BTN 3-bets to 7.5bb, CO calls."),
    ]

    public static func named(_ id: String) -> Scenario? { every.first { $0.id == id } }
}
