import DesignSystem
import SolverKit
import SwiftUI

/// Right-hand panel: what can happen at this node + summary stats.
struct NodePanel: View {
    let session: SolverSession
    let node: NodeInfo
    let matrix: MatrixData

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch node.kind {
            case .action: ActionChooser(session: session, node: node)
            case .chance: ChanceChooser(session: session, node: node)
            case .terminal: TerminalSummary(session: session, node: node)
            }
            summary
        }
    }

    private var summary: some View {
        Panel("Node", systemImage: "chart.bar.doc.horizontal") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    StatTile("Pot", value: Fmt.bb(node.pot, decimals: 2))
                    StatTile("Iterations", value: "\(node.iteration)",
                             caption: String(format: "%.3f%% expl.", node.exploitability))
                }
                ForEach(0..<2, id: \.self) { p in
                    GridRow {
                        StatTile("\(session.solvedName(p)) EV", value: Fmt.bb(node.rangeEV(p), decimals: 2),
                                 caption: "\(combos(p)) combos", tint: Theme.playerColor(p))
                        StatTile("\(session.solvedName(p)) equity", value: Fmt.pct(node.rangeEquity(p)),
                                 tint: Theme.playerColor(p))
                    }
                }
            }
        }
    }

    private func combos(_ p: Int) -> String {
        String(format: "%.1f", node.players[p].hands.reduce(Float(0)) { $0 + $1.reach })
    }
}

// MARK: - Action node

struct ActionChooser: View {
    let session: SolverSession
    let node: NodeInfo

    var body: some View {
        let freqs = session.matrix?.isActing == true ? session.matrix!.frequencies : node.actionFrequencies
        let evs = session.matrix?.isActing == true ? session.matrix!.actionEVs : []
        let p = node.player ?? 0
        let total = node.players[p].hands.reduce(Float(0)) { $0 + $1.reach }
        Panel {
            HStack(spacing: 6) {
                Circle().fill(Theme.playerColor(p)).frame(width: 8, height: 8)
                Text("\(session.solvedName(p)) to act").font(.headline)
                Spacer()
                Text(String(format: "%.1f combos", total)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            FrequencyBar(actions: node.actions, frequencies: freqs, height: 12)
            VStack(spacing: 6) {
                ForEach(Array(node.actions.enumerated()), id: \.offset) { i, a in
                    ActionRow(action: a, color: Theme.actionColor(node.actions, i),
                              frequency: i < freqs.count ? freqs[i] : 0,
                              combos: (i < freqs.count ? freqs[i] : 0) * total,
                              ev: i < evs.count ? evs[i] : nil,
                              shortcut: i < 9 ? i + 1 : nil) {
                        session.take(action: i)
                    }
                    .disabled(session.isLoadingNode)
                }
            }
        }
    }
}

struct ActionRow: View {
    let action: ActionInfo
    let color: Color
    let frequency: Float
    let combos: Float
    let ev: Float?
    let shortcut: Int?
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        let button = Button(action: onTap) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.label).font(.callout.weight(.semibold))
                    HStack(spacing: 6) {
                        Text(String(format: "%.1f combos", combos))
                        if let ev { Text("EV \(Fmt.bb(ev, decimals: 2))") }
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Fmt.pct(frequency))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
                if let shortcut {
                    Text("⌘\(shortcut)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(color.opacity(hovering ? 0.2 : 0.09))
            }
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(color.opacity(0.10))
                        .frame(width: g.size.width * CGFloat(frequency))
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Take this action")

        if let shortcut {
            button.keyboardShortcut(KeyEquivalent(Character("\(shortcut)")), modifiers: .command)
        } else {
            button
        }
    }
}

// MARK: - Chance node

struct ChanceChooser: View {
    let session: SolverSession
    let node: NodeInfo
    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    private var available: Set<String> { Set(node.chanceCards) }
    private var nextStreet: String { node.board.count == 3 ? "turn" : "river" }

    var body: some View {
        Panel("Deal the \(nextStreet)", systemImage: "rectangle.stack.badge.plus") {
            Grid(horizontalSpacing: 3, verticalSpacing: 4) {
                ForEach(Suit.allCases.reversed(), id: \.self) { suit in
                    GridRow {
                        ForEach(Rank.descending, id: \.self) { rank in
                            let card = Card(rank, suit)
                            let ok = available.contains(card.description)
                            Button {
                                session.deal(card.description)
                            } label: {
                                PlayingCardView(card, width: 20, dimmed: !ok)
                            }
                            .buttonStyle(.plain)
                            .disabled(!ok || session.isLoadingNode)
                            .help(card.description)
                        }
                    }
                }
            }
            HStack {
                TextField("Type a card, e.g. Kh", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .focused($fieldFocused)
                    .onSubmit(dealTyped)
                Button {
                    session.dealRandom()
                } label: {
                    Label("Random", systemImage: "dice")
                }
                .keyboardShortcut("d", modifiers: .command)
                .help("Deal a random card (⌘D)")
            }
            .controlSize(.small)
            if !typed.isEmpty, Card(typed).map({ !available.contains($0.description) }) ?? true {
                Text("Not an available card").font(.caption).foregroundStyle(.orange)
            }
        }
        .onAppear { fieldFocused = true }
    }

    private func dealTyped() {
        guard let c = Card(typed), available.contains(c.description) else { return }
        typed = ""
        session.deal(c.description)
    }
}

// MARK: - Terminal

struct TerminalSummary: View {
    let session: SolverSession
    let node: NodeInfo

    private var outcome: String {
        guard let t = node.terminal else { return "Hand over" }
        if t.hasPrefix("OOP") { return t.replacingOccurrences(of: "OOP", with: session.solvedName(0)) }
        if t.hasPrefix("IP") { return t.replacingOccurrences(of: "IP", with: session.solvedName(1)) }
        return t
    }

    private var icon: String { node.terminal?.contains("fold") == true ? "flag.fill" : "eye.fill" }

    var body: some View {
        Panel {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.title2).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(outcome).font(.title3.weight(.semibold))
                    Text("Pot \(Fmt.bb(node.pot, decimals: 2)) · contributions \(Fmt.bb(node.contrib[0], decimals: 1)) / \(Fmt.bb(node.contrib[1], decimals: 1))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text(node.terminal?.contains("fold") == true
                 ? "The remaining player wins the pot. EVs show each hand's share."
                 : "Hands go to showdown. EV and equity are evaluated on the final board.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Back", systemImage: "chevron.left") { session.back() }
                Button("Start of tree", systemImage: "house") { session.toRoot() }
            }
        }
    }
}
