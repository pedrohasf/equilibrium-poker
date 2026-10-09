import AppKit
import BenchKit
import DesignSystem
import SolverKit
import SwiftUI

/// Chart palette (validated categorical slots 1–3 + fixed status colours), light/dark selected.
enum Viz {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        func c(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? c(dark) : c(light)
        })
    }

    static let series1 = dynamic(0x2a78d6, 0x3987e5) // blue
    static let series2 = dynamic(0xeb6834, 0xd95926) // orange
    static let series3 = dynamic(0x1baf7a, 0x199e70) // aqua
    static let reference = dynamic(0x898781, 0x898781) // baselines: muted ink
    static let grid = dynamic(0xe1e0d9, 0x2c2c2a)

    static let good = Color(red: 0x0c / 255, green: 0xa3 / 255, blue: 0x0c / 255)
    static let warning = Color(red: 0xfa / 255, green: 0xb2 / 255, blue: 0x19 / 255)
    static let serious = Color(red: 0xec / 255, green: 0x83 / 255, blue: 0x5a / 255)
    static let critical = Color(red: 0xd0 / 255, green: 0x3b / 255, blue: 0x3b / 255)

    /// Fixed colour per street (colour follows the entity, never its rank).
    static func street(_ s: Street) -> Color {
        switch s {
        case .river: return series1
        case .turn: return series2
        case .flop: return series3
        }
    }

    static func decisionType(_ t: DecisionType) -> Color { t == .facingBet ? series1 : series2 }
}

/// Status of one answer: drives icon + label + colour together (never colour alone).
enum AnswerGrade {
    case best, fine, costly, blunder, invalid

    init(_ s: DecisionScore) {
        if !s.valid { self = .invalid } else if s.isBest { self = .best } else if s.blunder { self = .blunder }
        else if s.evLossPot > 0.05 { self = .costly } else { self = .fine }
    }

    var color: Color {
        switch self {
        case .best: return Viz.good
        case .fine: return Viz.good.opacity(0.7)
        case .costly: return Viz.serious
        case .blunder: return Viz.critical
        case .invalid: return .secondary
        }
    }

    var icon: String {
        switch self {
        case .best: return "checkmark.circle.fill"
        case .fine: return "checkmark.circle"
        case .costly: return "exclamationmark.circle"
        case .blunder: return "xmark.octagon.fill"
        case .invalid: return "questionmark.circle"
        }
    }

    var title: String {
        switch self {
        case .best: return "Best"
        case .fine: return "Close"
        case .costly: return "Costly"
        case .blunder: return "Blunder"
        case .invalid: return "Invalid"
        }
    }
}

struct GradeBadge: View {
    let grade: AnswerGrade
    var body: some View {
        Label(grade.title, systemImage: grade.icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(grade.color)
            .labelStyle(.titleAndIcon)
    }
}

/// Small capsule tag, e.g. street or position.
struct Tag: View {
    let text: String
    var tint: Color = .secondary

    init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint == .secondary ? Color.secondary : Color.primary)
    }
}

/// Coloured chip for an action label, keyed by the solver's action colours.
struct ActionChip: View {
    let actions: [SpotAction]
    let index: Int?

    var body: some View {
        if let i = index, actions.indices.contains(i) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.actionColor(actions.map(\.actionInfo), i)).frame(width: 3, height: 13)
                Text(actions[i].label).font(.callout.monospacedDigit())
            }
        } else {
            Text("No valid action").font(.callout).foregroundStyle(.secondary)
        }
    }
}

extension PlayerKind {
    var icon: String {
        switch self {
        case .decisionModel: return "scope"
        case .llm: return "sparkles"
        case .baseline: return "cpu"
        }
    }

    /// Series colour for charts that compare player groups.
    var tint: Color {
        switch self {
        case .decisionModel: return Viz.series1
        case .llm: return Viz.series3
        case .baseline: return Viz.reference
        }
    }
}

/// "Decision" capsule marking System One decision models.
struct DecisionBadge: View {
    var body: some View {
        Tag("Decision", tint: Viz.series1)
            .help("OpenRouter System One decision model: answers a typed choice question with probabilities; output is free")
    }
}

extension ModelScore {
    // Sort keys for distribution metrics; players without probabilities sort last.
    var mixedLossSort: Double { overall.meanMixedEVLossPot ?? .infinity }
    var tvSort: Double { overall.meanTVDistance ?? .infinity }
    var bestProbSort: Double { overall.meanBestActionProbability ?? -1 }

    var score: Double { overall.gtoScore }
    var lossPot: Double { overall.meanEVLossPot }
    var lossBB: Double { overall.meanEVLoss }
    var accuracy: Double { overall.accuracy }
    var approved: Double { overall.approvedRate }
    var blunders: Double { overall.blunderRate }
    var invalid: Double { overall.invalidRate }

    /// Short name for chart labels: "openai/gpt-5 · low" → "gpt-5 · low".
    var shortLabel: String {
        if isBaseline { return label }
        let parts = label.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : label
    }
}

enum BenchFmt {
    static func pctPot(_ x: Double, decimals: Int = 1) -> String { String(format: "%.\(decimals)f%%", x * 100) }
    static func score(_ x: Double) -> String { String(format: "%.1f", x) }
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1e3) }
        return "\(n)"
    }
    static func price(_ perToken: Double?) -> String {
        guard let p = perToken else { return "–" }
        let m = p * 1_000_000
        if m == 0 { return "free" }
        return m < 1 ? String(format: "$%.2f", m) : String(format: "$%.1f", m)
    }
}
