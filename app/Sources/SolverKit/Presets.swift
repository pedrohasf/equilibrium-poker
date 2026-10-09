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

    public init(id: String, name: String, oopName: String, ipName: String, rangeOOP: String, rangeIP: String,
                pot: Double, stack: Double, summary: String) {
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

public enum Scenarios {
    public static let all: [Scenario] = [
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

    public static func named(_ id: String) -> Scenario? { all.first { $0.id == id } }
}
