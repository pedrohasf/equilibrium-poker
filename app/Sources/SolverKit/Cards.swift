import Foundation

/// Card ranks, deuce = 0 ... ace = 12 (matches the Rust core).
public enum Rank: Int, CaseIterable, Comparable, Sendable, Codable {
    case two, three, four, five, six, seven, eight, nine, ten, jack, queen, king, ace

    public static let chars: [Character] = Array("23456789TJQKA")

    public var char: Character { Rank.chars[rawValue] }

    public init?(char: Character) {
        guard let i = Rank.chars.firstIndex(of: Character(char.uppercased())) else { return nil }
        self.init(rawValue: i)
    }

    /// Ranks from ace down to deuce, the order used by the 13x13 hand grid.
    public static let descending: [Rank] = Rank.allCases.reversed()

    public static func < (a: Rank, b: Rank) -> Bool { a.rawValue < b.rawValue }
}

public enum Suit: Int, CaseIterable, Sendable, Codable {
    case clubs, diamonds, hearts, spades

    public static let chars: [Character] = Array("cdhs")
    public var char: Character { Suit.chars[rawValue] }
    public var symbol: String { ["♣", "♦", "♥", "♠"][rawValue] }

    public init?(char: Character) {
        guard let i = Suit.chars.firstIndex(of: Character(char.lowercased())) else { return nil }
        self.init(rawValue: i)
    }
}

/// A playing card encoded as `rank * 4 + suit` (0..<52), identical to the solver core.
public struct Card: Hashable, Comparable, Sendable, Codable, CustomStringConvertible, Identifiable {
    public let index: Int

    public init(index: Int) {
        precondition((0..<52).contains(index))
        self.index = index
    }

    public init(_ rank: Rank, _ suit: Suit) {
        self.index = rank.rawValue * 4 + suit.rawValue
    }

    public init?(_ text: String) {
        let chars = Array(text.trimmingCharacters(in: .whitespaces))
        guard chars.count == 2, let r = Rank(char: chars[0]), let s = Suit(char: chars[1]) else { return nil }
        self.init(r, s)
    }

    public var id: Int { index }
    public var rank: Rank { Rank(rawValue: index >> 2)! }
    public var suit: Suit { Suit(rawValue: index & 3)! }
    public var description: String { "\(rank.char)\(suit.char)" }

    public static func < (a: Card, b: Card) -> Bool { a.index < b.index }

    public static let deck: [Card] = (0..<52).map(Card.init(index:))

    /// Parses "QsJh2h", "Qs Jh 2h" or "Qs,Jh,2h".
    public static func parseList(_ text: String) -> [Card]? {
        let cleaned = text.filter { $0.isLetter || $0.isNumber }
        guard cleaned.count % 2 == 0 else { return nil }
        var out: [Card] = []
        var i = cleaned.startIndex
        while i < cleaned.endIndex {
            let j = cleaned.index(i, offsetBy: 2)
            guard let c = Card(String(cleaned[i..<j])), !out.contains(c) else { return nil }
            out.append(c)
            i = j
        }
        return out
    }
}

public extension Array where Element == Card {
    var text: String { map(\.description).joined(separator: " ") }
    var compactText: String { map(\.description).joined() }
}

/// Two-card hand. `index` matches the solver's combo index (0..<1326).
public struct Combo: Hashable, Sendable, CustomStringConvertible {
    public let high: Card
    public let low: Card

    public init(_ a: Card, _ b: Card) {
        precondition(a != b)
        if a > b { high = a; low = b } else { high = b; low = a }
    }

    public init?(_ text: String) {
        guard let cards = Card.parseList(text), cards.count == 2 else { return nil }
        self.init(cards[0], cards[1])
    }

    public var index: Int { high.index * (high.index - 1) / 2 + low.index }
    public var cards: [Card] { [high, low] }
    public var isPair: Bool { high.rank == low.rank }
    public var isSuited: Bool { high.suit == low.suit }

    /// Display with the higher rank first ("AsKd").
    public var description: String {
        let (a, b) = high.rank >= low.rank ? (high, low) : (low, high)
        return "\(a)\(b)"
    }

    public func conflicts(with cards: [Card]) -> Bool { cards.contains(high) || cards.contains(low) }

    public var handClass: HandClass {
        let (r1, r2) = high.rank >= low.rank ? (high.rank, low.rank) : (low.rank, high.rank)
        if r1 == r2 { return HandClass(high: r1, low: r2, kind: .pair) }
        return HandClass(high: r1, low: r2, kind: isSuited ? .suited : .offsuit)
    }

    /// All 1326 combos in solver index order.
    public static let all: [Combo] = {
        var out = [Combo?](repeating: nil, count: 1326)
        for hi in 1..<52 {
            for lo in 0..<hi {
                let c = Combo(Card(index: hi), Card(index: lo))
                out[c.index] = c
            }
        }
        return out.map { $0! }
    }()

    private static let lookup: [String: Int] = {
        var d: [String: Int] = [:]
        for c in all {
            d[c.description] = c.index
            d["\(c.low)\(c.high)"] = c.index
            d["\(c.high)\(c.low)"] = c.index
        }
        return d
    }()

    /// Fast lookup for strings like "AsKd" (either card order).
    public static func index(of text: String) -> Int? { lookup[text] }
}

/// One of the 169 strategically distinct starting hands ("AKs", "T9o", "77").
public struct HandClass: Hashable, Sendable, CustomStringConvertible, Identifiable {
    public enum Kind: Sendable { case pair, suited, offsuit }

    public let high: Rank
    public let low: Rank
    public let kind: Kind

    public init(high: Rank, low: Rank, kind: Kind) {
        self.high = high
        self.low = low
        self.kind = kind
    }

    public var id: String { description }

    public var description: String {
        switch kind {
        case .pair: return "\(high.char)\(low.char)"
        case .suited: return "\(high.char)\(low.char)s"
        case .offsuit: return "\(high.char)\(low.char)o"
        }
    }

    /// Grid position: row/column 0 = ace. Suited hands sit above the diagonal.
    public var gridPosition: (row: Int, col: Int) {
        let h = 12 - high.rawValue, l = 12 - low.rawValue
        switch kind {
        case .pair: return (h, h)
        case .suited: return (h, l)
        case .offsuit: return (l, h)
        }
    }

    public static func at(row: Int, col: Int) -> HandClass {
        let r = Rank(rawValue: 12 - row)!, c = Rank(rawValue: 12 - col)!
        if row == col { return HandClass(high: r, low: r, kind: .pair) }
        if row < col { return HandClass(high: r, low: c, kind: .suited) }
        return HandClass(high: c, low: r, kind: .offsuit)
    }

    public var comboCount: Int {
        switch kind {
        case .pair: return 6
        case .suited: return 4
        case .offsuit: return 12
        }
    }

    public var combos: [Combo] { HandClass.combosByClass[self] ?? [] }

    private static let combosByClass: [HandClass: [Combo]] = Dictionary(grouping: Combo.all, by: \.handClass)

    public static let grid: [[HandClass]] = (0..<13).map { r in (0..<13).map { c in HandClass.at(row: r, col: c) } }
}
