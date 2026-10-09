import AppKit
import DesignSystem
import SolverKit
import SwiftUI

/// Phase 3: GTO-Wizard-style tree browser.
struct ResultsView: View {
    @Bindable var session: SolverSession
    @State private var hovered: HandClass?

    var body: some View {
        if let node = session.node, let matrix = session.matrix {
            VStack(spacing: 0) {
                ResultsHeader(session: session, node: node)
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    matrixColumn(node: node, matrix: matrix)
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    ScrollView {
                        NodePanel(session: session, node: node, matrix: matrix)
                            .padding(16)
                    }
                    .frame(width: 340)
                }
            }
            .overlay(alignment: .top) {
                if let err = session.queryError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .glassEffect(in: Capsule())
                        .foregroundStyle(.orange)
                        .padding(.top, 70)
                }
            }
        } else if session.isLoadingNode {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading strategy…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateView("No solution yet", systemImage: "square.grid.3x3",
                           message: "Configure a spot in Setup and press Solve (⌘R).")
                .onAppear { if session.solver != nil { session.toRoot() } }
        }
    }

    // MARK: Matrix column

    private func matrixColumn(node: NodeInfo, matrix: MatrixData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("Display", selection: $session.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)

                Spacer()

                Picker("Player", selection: Binding(
                    get: { session.viewedPlayer },
                    set: { p in session.viewedPlayerOverride = (p == node.player) ? nil : p }
                )) {
                    ForEach(0..<2, id: \.self) { p in
                        Text(session.solvedName(p) + (node.player == p ? " ●" : "")).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 200)
                .help("Whose range to show (● = to act)")
            }

            StrategyMatrixView(matrix: matrix, mode: session.displayMode,
                               selected: $session.selectedClass, hovered: $hovered)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(session.isLoadingNode ? 0.55 : 1)
                .overlay {
                    if session.isLoadingNode {
                        ProgressView().controlSize(.regular)
                            .padding(14)
                            .glassEffect(in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: session.isLoadingNode)
                .contextMenu {
                    Button("Copy \(session.solvedName(matrix.player)) range at this node") {
                        copyRange(node: node, player: matrix.player)
                    }
                    if session.selectedClass != nil {
                        Button("Clear selection") { session.selectedClass = nil }
                    }
                }

            MatrixLegend(matrix: matrix, mode: session.displayMode, name: session.solvedName(matrix.player))
            HoverLine(matrix: matrix, hovered: hovered ?? session.selectedClass)
        }
    }

    private func copyRange(node: NodeInfo, player: Int) {
        var r = HandRange()
        for h in node.players[player].hands {
            if let i = Combo.index(of: h.combo) { r.weights[i] = min(1, h.reach) }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(r.text, forType: .string)
    }
}

// MARK: - Header & breadcrumbs

struct ResultsHeader: View {
    let session: SolverSession
    let node: NodeInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 18) {
                BoardView(node.board.compactMap { Card($0) }, slots: 5, width: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.street.capitalized).font(.title3.weight(.semibold))
                    Text("Pot \(Fmt.bb(node.pot, decimals: 2))")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Divider().frame(height: 36)
                ForEach(0..<2, id: \.self) { p in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Circle().fill(Theme.playerColor(p)).frame(width: 7, height: 7)
                            Text(session.solvedName(p)).font(.callout.weight(.semibold))
                            if node.player == p {
                                Text("to act").font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Theme.playerColor(p).opacity(0.2), in: Capsule())
                            }
                        }
                        Text("Stack \(Fmt.bb(node.stacks[p], decimals: 1))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(String(format: "%.3f%% pot", node.exploitability))
                        .font(.callout.weight(.semibold).monospacedDigit())
                    Text("exploitability · \(node.iteration) it")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Breadcrumbs(session: session, node: node)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct Breadcrumbs: View {
    let session: SolverSession
    let node: NodeInfo

    private var rootStreet: String {
        let n = (Card.parseList(session.solvedConfig?.board ?? "") ?? []).count
        return n >= 5 ? "River" : n == 4 ? "Turn" : "Flop"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    crumb(depth: 0, isLast: session.path.isEmpty) {
                        Label(rootStreet, systemImage: "house").labelStyle(.titleAndIcon)
                    }
                    ForEach(Array(session.path.enumerated()), id: \.offset) { i, step in
                        Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                        crumb(depth: i + 1, isLast: i == session.path.count - 1) {
                            stepLabel(step, history: i < node.history.count ? node.history[i] : "")
                        }
                    }
                    if session.isLoadingNode {
                        ProgressView().controlSize(.mini).padding(.leading, 4)
                    }
                    Color.clear.frame(width: 1).id("end")
                }
                .font(.callout)
            }
            .onChange(of: session.path) { proxy.scrollTo("end") }
        }
    }

    @ViewBuilder private func stepLabel(_ step: PathStep, history: String) -> some View {
        switch step {
        case .card(let c):
            if let card = Card(c) { CardText(card, font: .callout.monospaced().weight(.bold)) } else { Text(c) }
        case .action:
            let parts = history.components(separatedBy: ": ")
            let p = parts.first == "IP" ? 1 : 0
            HStack(spacing: 4) {
                Circle().fill(Theme.playerColor(p)).frame(width: 6, height: 6)
                Text(session.solvedName(p)).foregroundStyle(.secondary)
                Text(parts.count > 1 ? parts[1] : history)
            }
        }
    }

    private func crumb<L: View>(depth: Int, isLast: Bool, @ViewBuilder label: () -> L) -> some View {
        Button {
            session.jump(toDepth: depth)
        } label: {
            label()
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(isLast ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isLast)
    }
}

// MARK: - Legend & hover

struct MatrixLegend: View {
    let matrix: MatrixData
    let mode: DisplayMode
    let name: String

    var body: some View {
        HStack(spacing: 14) {
            switch mode {
            case .strategy where matrix.isActing:
                ForEach(Array(matrix.actions.enumerated()), id: \.offset) { i, a in
                    LegendDot(Theme.actionColor(matrix.actions, i), a.label)
                }
                Spacer()
                Text("bar height = share of class in range").font(.caption).foregroundStyle(.tertiary)
            case .strategy, .range:
                LegendDot(Theme.playerColor(matrix.player), "\(name) range")
                Spacer()
                Text("bar height = reach / combos").font(.caption).foregroundStyle(.tertiary)
            case .ev:
                gradient(lo: Fmt.signedBB(Double(matrix.minEV - matrix.rangeEV), decimals: 1),
                         mid: "avg \(Fmt.bb(matrix.rangeEV, decimals: 2))",
                         hi: Fmt.signedBB(Double(matrix.maxEV - matrix.rangeEV), decimals: 1))
            case .equity:
                gradient(lo: "0%", mid: "50%", hi: "100%")
            }
        }
        .frame(height: 18)
    }

    private func gradient(lo: String, mid: String, hi: String) -> some View {
        HStack(spacing: 8) {
            Text(lo).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            LinearGradient(colors: [Theme.diverging(-1), Theme.diverging(0), Theme.diverging(1)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 160, height: 8)
                .clipShape(Capsule())
            Text(hi).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(mid).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            Spacer()
        }
    }
}

struct HoverLine: View {
    let matrix: MatrixData
    let hovered: HandClass?

    var body: some View {
        HStack(spacing: 10) {
            if let h = hovered {
                let s = matrix.stats(h)
                Text(h.description).font(.callout.weight(.bold).monospaced())
                Text(String(format: "%.2f / %d combos", s.reach, h.comboCount))
                    .foregroundStyle(.secondary)
                if !s.isEmpty {
                    if matrix.isActing {
                        FrequencyBar(actions: matrix.actions, frequencies: s.frequencies, height: 8)
                            .frame(width: 120)
                        ForEach(Array(s.frequencies.enumerated()), id: \.offset) { i, f in
                            if f >= 0.005 {
                                Text(Fmt.pct(f, decimals: 0)).foregroundStyle(Theme.actionColor(matrix.actions, i))
                            }
                        }
                    }
                    Text("EV \(Fmt.bb(s.ev, decimals: 2))")
                    Text("Eq \(Fmt.pct(s.equity))")
                }
            } else {
                Text("Hover a hand for details · click to inspect").foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .font(.callout.monospacedDigit())
        .frame(height: 20)
    }
}
