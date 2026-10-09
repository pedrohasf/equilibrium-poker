import DesignSystem
import SolverKit
import SwiftUI

/// Inspector for the selected hand class: every combo with strategy, EV and equity.
struct HandInspector: View {
    let session: SolverSession

    var body: some View {
        if let node = session.node, let matrix = session.matrix {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let cls = session.selectedClass {
                        classDetail(cls, node: node, matrix: matrix)
                    } else {
                        overview(matrix)
                    }
                }
                .padding(14)
            }
        } else {
            EmptyStateView("Nothing selected", systemImage: "hand.point.up.left",
                           message: "Solve a spot and click a hand in the matrix.")
        }
    }

    // MARK: Overview (no selection)

    private func overview(_ matrix: MatrixData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Range overview").font(.headline)
            Text("Click a hand in the matrix to see each combo.")
                .font(.callout).foregroundStyle(.secondary)
            if matrix.isActing {
                ForEach(Array(matrix.actions.enumerated()), id: \.offset) { i, a in
                    HStack {
                        LegendDot(Theme.actionColor(matrix.actions, i), a.label)
                        Spacer()
                        Text(Fmt.pct(matrix.frequencies[i])).monospacedDigit()
                        Text(Fmt.bb(matrix.actionEVs[i], decimals: 2))
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                    }
                    .font(.callout)
                }
                Divider()
            }
            topHands(matrix)
        }
    }

    private func topHands(_ matrix: MatrixData) -> some View {
        let ranked = matrix.cells.filter { !$0.isEmpty }.sorted { $0.ev > $1.ev }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Highest EV classes").font(.subheadline.weight(.semibold))
            ForEach(ranked.prefix(8), id: \.handClass) { s in
                Button {
                    session.selectedClass = s.handClass
                } label: {
                    HStack {
                        Text(s.handClass.description).font(.callout.weight(.semibold).monospaced())
                        if matrix.isActing {
                            FrequencyBar(actions: matrix.actions, frequencies: s.frequencies, height: 6).frame(width: 70)
                        }
                        Spacer()
                        Text(Fmt.bb(s.ev, decimals: 2)).font(.callout.monospacedDigit())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Class detail

    private func classDetail(_ cls: HandClass, node: NodeInfo, matrix: MatrixData) -> some View {
        let s = matrix.stats(cls)
        let hands = s.hands.map { node.players[matrix.player].hands[$0] }.sorted { $0.ev > $1.ev }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(cls.description).font(.system(size: 28, weight: .bold, design: .rounded))
                Text(session.solvedName(matrix.player)).foregroundStyle(Theme.playerColor(matrix.player))
                Spacer()
                Button {
                    session.selectedClass = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            if s.isEmpty {
                Text("Not in \(session.solvedName(matrix.player))'s range at this node.")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    StatTile("Combos", value: String(format: "%.2f", s.reach), caption: "of \(cls.comboCount)")
                    StatTile("EV", value: Fmt.bb(s.ev, decimals: 2))
                    StatTile("Equity", value: Fmt.pct(s.equity))
                }
                if matrix.isActing {
                    FrequencyBar(actions: matrix.actions, frequencies: s.frequencies, height: 10)
                    actionTable(s, matrix: matrix)
                }
                Divider()
                Text("Combos").font(.subheadline.weight(.semibold))
                ForEach(hands, id: \.combo) { h in
                    ComboRow(hand: h, actions: matrix.actions)
                }
            }
        }
    }

    private func actionTable(_ s: ClassStats, matrix: MatrixData) -> some View {
        let best = s.actionEVs.indices.max { s.actionEVs[$0] < s.actionEVs[$1] }
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(Array(matrix.actions.enumerated()), id: \.offset) { i, a in
                GridRow {
                    LegendDot(Theme.actionColor(matrix.actions, i), a.label)
                    Text(Fmt.pct(s.frequencies[i])).monospacedDigit().gridColumnAlignment(.trailing)
                    Text(Fmt.bb(s.actionEVs[i], decimals: 2)).monospacedDigit()
                        .fontWeight(i == best ? .bold : .regular)
                        .foregroundStyle(i == best ? Theme.positive : .primary)
                        .gridColumnAlignment(.trailing)
                }
            }
        }
        .font(.callout)
    }
}

/// One combo: cards, strategy bar, EV, equity and per-action EVs.
struct ComboRow: View {
    let hand: HandInfo
    let actions: [ActionInfo]

    var body: some View {
        let best = hand.actionEvs.indices.max { hand.actionEvs[$0] < hand.actionEvs[$1] }
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                ComboText(hand.combo, font: .callout.monospaced().weight(.bold))
                if hand.reach < hand.weight - 1e-4 || hand.weight < 0.999 {
                    Text(Fmt.pct(hand.reach, decimals: 0)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        .help("Reach (start weight × probability of getting here)")
                }
                Spacer()
                Text(Fmt.bb(hand.ev, decimals: 2)).font(.callout.weight(.semibold).monospacedDigit())
                Text(Fmt.pct(hand.equity, decimals: 0))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            if !actions.isEmpty, hand.strategy.count == actions.count {
                FrequencyBar(actions: actions, frequencies: hand.strategy, height: 6)
                HStack(spacing: 8) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { i, _ in
                        HStack(spacing: 3) {
                            Circle().fill(Theme.actionColor(actions, i)).frame(width: 5, height: 5)
                            Text(Fmt.pct(hand.strategy[i], decimals: 0))
                            if i < hand.actionEvs.count {
                                Text(String(format: "%.2f", hand.actionEvs[i]))
                                    .fontWeight(i == best ? .bold : .regular)
                                    .foregroundStyle(i == best ? Theme.positive : .secondary)
                            }
                        }
                    }
                }
                .font(.caption2.monospacedDigit())
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
