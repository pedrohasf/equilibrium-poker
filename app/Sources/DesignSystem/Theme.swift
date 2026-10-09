import SolverKit
import SwiftUI

/// Shared visual language for Equilibrium.
///
/// Direction: a quiet, dark-leaning "ink on felt" look. Chrome stays neutral
/// (system materials / Liquid Glass) so that the only saturated colour on
/// screen is *information*: action frequencies, EVs and suits.
public enum Theme {
    // MARK: Surfaces
    public static let felt = Color(red: 0.055, green: 0.16, blue: 0.13)
    public static let feltDeep = Color(red: 0.03, green: 0.09, blue: 0.075)
    public static let accent = Color(red: 0.16, green: 0.72, blue: 0.58) // teal-mint, matches app icon family
    public static let gold = Color(red: 0.93, green: 0.74, blue: 0.36)

    // MARK: Semantic
    public static let positive = Color(red: 0.25, green: 0.78, blue: 0.48)
    public static let negative = Color(red: 0.93, green: 0.36, blue: 0.36)
    public static let neutral = Color.secondary

    // MARK: Players
    public static let oop = Color(red: 0.42, green: 0.62, blue: 0.98)
    public static let ip = Color(red: 0.98, green: 0.62, blue: 0.36)

    public static func playerColor(_ p: Int) -> Color { p == 0 ? oop : ip }

    // MARK: Actions
    public static let fold = Color(red: 0.36, green: 0.49, blue: 0.69)
    public static let check = Color(red: 0.30, green: 0.69, blue: 0.48)
    public static let call = Color(red: 0.24, green: 0.62, blue: 0.42)
    /// Bets graduate from amber (small) to crimson (large); all-in is a deep plum.
    public static let betRamp: [Color] = [
        Color(red: 0.95, green: 0.70, blue: 0.27),
        Color(red: 0.93, green: 0.52, blue: 0.24),
        Color(red: 0.88, green: 0.36, blue: 0.24),
        Color(red: 0.80, green: 0.22, blue: 0.27),
    ]
    public static let allin = Color(red: 0.55, green: 0.13, blue: 0.33)

    /// Colour for action `index` among the node's `actions`.
    public static func actionColor(_ actions: [ActionInfo], _ index: Int) -> Color {
        guard actions.indices.contains(index) else { return .gray }
        let a = actions[index]
        switch a.kind {
        case .fold: return fold
        case .check: return check
        case .call: return call
        case .allin: return allin
        case .bet, .raise:
            let aggressive = actions.enumerated().filter { $0.element.kind == .bet || $0.element.kind == .raise }
            let rank = aggressive.firstIndex { $0.offset == index } ?? 0
            if aggressive.count <= 1 { return betRamp[1] }
            let t = Double(rank) / Double(aggressive.count - 1)
            return betRamp[min(betRamp.count - 1, Int((t * Double(betRamp.count - 1)).rounded()))]
        }
    }

    /// Four-colour deck: ♠ ink, ♥ red, ♦ blue, ♣ green.
    public static func suitColor(_ s: Suit) -> Color {
        switch s {
        case .spades: return Color(red: 0.13, green: 0.14, blue: 0.17)
        case .hearts: return Color(red: 0.84, green: 0.18, blue: 0.22)
        case .diamonds: return Color(red: 0.16, green: 0.42, blue: 0.86)
        case .clubs: return Color(red: 0.13, green: 0.58, blue: 0.32)
        }
    }

    /// Red→neutral→green scale for EV-like values in [-1, 1].
    public static func diverging(_ t: Double) -> Color {
        let x = max(-1, min(1, t))
        return x >= 0 ? positive.opacity(0.15 + 0.85 * x) : negative.opacity(0.15 + 0.85 * -x)
    }
}

// MARK: - Formatting

public enum Fmt {
    public static func bb(_ x: Double, decimals: Int = 1) -> String {
        guard x.isFinite else { return "–" }
        return String(format: "%.\(decimals)f", x) + " bb"
    }

    public static func bb(_ x: Float, decimals: Int = 1) -> String { bb(Double(x), decimals: decimals) }

    public static func signedBB(_ x: Double, decimals: Int = 2) -> String {
        guard x.isFinite else { return "–" }
        return (x >= 0 ? "+" : "−") + String(format: "%.\(decimals)f", abs(x)) + " bb"
    }

    public static func pct(_ x: Double, decimals: Int = 1) -> String {
        guard x.isFinite else { return "–" }
        return String(format: "%.\(decimals)f%%", x * 100)
    }

    public static func pct(_ x: Float, decimals: Int = 1) -> String { pct(Double(x), decimals: decimals) }

    public static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
    }

    public static func duration(_ s: Double) -> String {
        if s < 1 { return String(format: "%.0f ms", s * 1000) }
        if s < 60 { return String(format: "%.1f s", s) }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    public static func usd(_ x: Double) -> String {
        if x == 0 { return "$0" }
        if x < 0.01 { return String(format: "$%.4f", x) }
        return String(format: "$%.2f", x)
    }
}
