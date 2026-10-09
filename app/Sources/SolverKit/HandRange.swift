import Foundation

/// A weighted preflop range over all 1326 combos (solver combo index order).
public struct HandRange: Hashable, Sendable, Codable {
    public var weights: [Float]

    public init() { weights = Array(repeating: 0, count: 1326) }

    public init(weights: [Float]) {
        precondition(weights.count == 1326)
        self.weights = weights
    }

    /// Parses PioSolver-style text ("AA,KK:0.5,A5s-A2s,T9s+") using the solver core.
    public init(parsing text: String) throws {
        self.weights = try GTOCore.parseRange(text)
    }

    public static let full = HandRange(weights: Array(repeating: 1, count: 1326))

    public subscript(combo: Combo) -> Float {
        get { weights[combo.index] }
        set { weights[combo.index] = max(0, min(1, newValue)) }
    }

    public var isEmpty: Bool { !weights.contains { $0 > 0 } }

    /// Weighted combo count.
    public var comboCount: Float { weights.reduce(0, +) }

    /// Fraction of all 1326 combos.
    public var percentOfHands: Float { comboCount / 1326 }

    public func weight(of cls: HandClass) -> Float {
        let cs = cls.combos
        return cs.reduce(0) { $0 + weights[$1.index] } / Float(cs.count)
    }

    public mutating func set(_ cls: HandClass, weight: Float) {
        for c in cls.combos { weights[c.index] = max(0, min(1, weight)) }
    }

    /// Canonical text form. Classes whose combos share one weight collapse to
    /// "AKs" / "AKs:0.5"; mixed classes list specific combos.
    public var text: String {
        var parts: [String] = []
        for row in HandClass.grid {
            for cls in row {
                let ws = cls.combos.map { weights[$0.index] }
                guard ws.contains(where: { $0 > 0 }) else { continue }
                if let first = ws.first, ws.allSatisfy({ abs($0 - first) < 1e-4 }) {
                    parts.append(first >= 0.9999 ? cls.description : "\(cls.description):\(Self.fmt(first))")
                } else {
                    for c in cls.combos where weights[c.index] > 0 {
                        let w = weights[c.index]
                        parts.append(w >= 0.9999 ? c.description : "\(c.description):\(Self.fmt(w))")
                    }
                }
            }
        }
        return parts.joined(separator: ",")
    }

    private static func fmt(_ w: Float) -> String {
        var s = String(format: "%.3f", w)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
