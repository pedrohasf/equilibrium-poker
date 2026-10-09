import ArenaKit
import DesignSystem
import OpenRouterKit
import SwiftUI

/// Small capsule marking System One decision models.
struct DecisionBadge: View {
    var mode: DecisionMode?
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "dial.medium")
            Text(mode == .mixed ? "Decision · mixed" : "Decision")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Theme.gold)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Theme.gold.opacity(0.14), in: Capsule())
        .help("System One decision model: answers with a probability per legal action instead of text")
    }
}

/// Compact probability bars over the action menu, the played action highlighted.
struct DecisionProbabilityView: View {
    let trace: DecisionTrace
    var fallback = false
    var compact = false

    private var maxP: Double { max(0.0001, trace.options.compactMap(\.probability).max() ?? 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 4) {
            HStack(spacing: 6) {
                Text(trace.mode == .mixed ? "Sampled from probabilities" : "Top choice (argmax)")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                if let c = trace.confidence {
                    Text("confidence \(Fmt.pct(c, decimals: 0))").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if fallback {
                    Label("defaulted", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(Theme.negative)
                        .help("Unknown key or failed request: replaced by check/fold")
                }
            }
            ForEach(Array(trace.options.enumerated()), id: \.offset) { _, o in row(o) }
        }
    }

    private func row(_ o: DecisionTrace.Option) -> some View {
        let played = o.key == trace.playedKey
        let top = o.key == trace.choiceKey && !played
        let p = o.probability ?? 0
        return HStack(spacing: 6) {
            Text(o.key)
                .font(.caption2.monospaced().weight(played ? .bold : .regular))
                .foregroundStyle(played ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: compact ? 104 : 120, alignment: .leading)
                .help(o.label)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(color(o.key).opacity(played ? 1 : 0.45))
                        .frame(width: max(p > 0 ? 3 : 0, g.size.width * p / maxP))
                }
            }
            .frame(height: compact ? 7 : 9)
            Text(o.probability.map { Fmt.pct($0, decimals: 0) } ?? "–")
                .font(.caption2.monospacedDigit().weight(played ? .bold : .regular))
                .foregroundStyle(played ? .primary : .secondary)
                .frame(width: 34, alignment: .trailing)
            Group {
                if played { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                else if top { Image(systemName: "arrow.up.circle").foregroundStyle(.secondary).help("Model's top choice") }
                else { Color.clear }
            }
            .font(.caption2)
            .frame(width: 12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(o.label): \(o.probability.map { Fmt.pct($0, decimals: 0) } ?? "no probability")\(played ? ", played" : "")")
    }

    private func color(_ key: String) -> Color {
        if key.hasPrefix("fold") { return Theme.fold }
        if key.hasPrefix("check") { return Theme.check }
        if key.hasPrefix("call") { return Theme.call }
        if key.hasPrefix("allin") { return Theme.allin }
        return Theme.betRamp[min(1, Theme.betRamp.count - 1)]
    }
}

/// Pretty JSON of the state a decision model received.
struct DecisionStateDisclosure: View {
    let state: String
    var body: some View {
        DisclosureGroup("State sent") {
            let pretty = (try? JSONDecoder().decode(JSONValue.self, from: Data(state.utf8)))?.prettyText ?? state
            ScrollView {
                Text(pretty).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
        .font(.caption)
    }
}
