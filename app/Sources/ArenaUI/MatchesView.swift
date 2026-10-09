import AppKit
import ArenaKit
import DesignSystem
import SolverKit
import SwiftUI

struct MatchesView: View {
    let store: ArenaStore
    @Binding var selection: String?

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.matches) { m in
                    MatchRow(match: m)
                        .tag(m.id)
                        .contextMenu {
                            Button("Copy Match ID") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(m.id, forType: .string)
                            }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([MatchStore.url(for: m.id)]) }
                            Divider()
                            Button("Delete", role: .destructive) {
                                if selection == m.id { selection = nil }
                                store.delete(m.id)
                            }
                        }
                }
            }
            .listStyle(.inset)
            .frame(width: 300)
            .overlay {
                if store.matches.isEmpty {
                    EmptyStateView("No matches yet", systemImage: "tray", message: "Start a match with ⌘N. Finished matches are saved here.")
                }
            }
            Divider()
            if let id = selection, let m = store.matches.first(where: { $0.id == id }) {
                MatchDetailView(match: m).id(m.id)
            } else {
                EmptyStateView("Select a match", systemImage: "rectangle.stack", message: "Results, charts and a hand-by-hand replay.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct MatchRow: View {
    let match: MatchRecord
    var body: some View {
        let a = match.summary?.players[0]
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                PlayerDot(player: 0)
                Text(match.players[0].displayName).font(.body.weight(.medium)).lineLimit(1)
                Text("vs").foregroundStyle(.secondary).font(.caption)
                PlayerDot(player: 1)
                Text(match.players[1].displayName).font(.body.weight(.medium)).lineLimit(1)
            }
            HStack {
                Text(match.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                Text("· \(match.hands.count) hands").font(.caption).foregroundStyle(.secondary)
                if match.status != .completed { StatusBadge(status: match.status).controlSize(.mini) }
                Spacer()
                if let a {
                    Text(String(format: "%+.1f", a.bb100)).font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(a.bb100 >= 0 ? Theme.positive : Theme.negative)
                        .help("Player A bb/100")
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct MatchDetailView: View {
    let match: MatchRecord
    @State private var selectedHand: Int?

    private var summary: MatchSummary { match.summary ?? MatchStats.summarize(match) }

    private var points: [CumulativePoint] {
        var net = 0.0, ev = 0.0
        return match.hands.enumerated().map { i, h in
            net += h.net(0)
            ev += h.evNet(0)
            return CumulativePoint(index: i + 1, hand: h.number, net: net, ev: ev)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                tiles
                Panel { CumulativeChart(points: points, playerName: match.players[0].displayName).frame(height: 200) }
                StatsComparison(match: match, summary: summary)
                HandBrowser(match: match, selection: $selectedHand)
            }
            .padding(20)
        }
        .onAppear { if selectedHand == nil { selectedHand = match.hands.max { $0.result.pot < $1.result.pot }?.number } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(match.title).font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    StatusBadge(status: match.status)
                    Text("\(match.id) · seed \(match.config.seed) · \(match.config.duplicate ? "duplicate" : "single") · \(match.hands.count) hands")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let e = match.error { Text(e).font(.caption).foregroundStyle(Theme.negative) }
            }
            Spacer()
        }
    }

    private var tiles: some View {
        let a = summary.players[0], b = summary.players[1]
        return Panel {
            HStack(spacing: 18) {
                StatTile("\(a.name) bb/100", value: String(format: "%+.1f", a.bb100),
                         caption: a.ci95.map { "95% CI ± \(String(format: "%.1f", $0))" } ?? "needs ≥ 2 pairs",
                         tint: a.bb100 >= 0 ? Theme.positive : Theme.negative)
                StatTile("All-in EV bb/100", value: String(format: "%+.1f", a.evBB100),
                         caption: a.evCI95.map { "± \(String(format: "%.1f", $0))" })
                StatTile("Net", value: Fmt.signedBB(a.netBB, decimals: 1), caption: "\(summary.units) \(match.config.duplicate ? "pairs" : "hands")")
                StatTile("Cost", value: Fmt.usd(a.cost + b.cost),
                         caption: "\(a.invalidActions + b.invalidActions) invalid actions")
            }
        }
    }
}

/// Side-by-side tendencies.
struct StatsComparison: View {
    let match: MatchRecord
    let summary: MatchSummary

    var body: some View {
        let a = summary.players[0], b = summary.players[1]
        Panel("Statistics", systemImage: "tablecells") {
            Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    HStack(spacing: 5) { PlayerDot(player: 0); Text(a.name).font(.caption.weight(.semibold)) }
                    HStack(spacing: 5) { PlayerDot(player: 1); Text(b.name).font(.caption.weight(.semibold)) }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                row("bb/100 (95% CI)", ci(a.bb100, a.ci95), ci(b.bb100, b.ci95), help: "Win rate over complete duplicate pairs")
                row("All-in EV bb/100", ci(a.evBB100, a.evCI95), ci(b.evBB100, b.evCI95), help: "Replaces all-in showdown outcomes by the equity share of the pot")
                row("VPIP", pct(a.vpip), pct(b.vpip), help: "Voluntarily put money in preflop")
                row("PFR", pct(a.pfr), pct(b.pfr), help: "Raised preflop")
                row("3-bet", pct(a.threeBet), pct(b.threeBet), help: "Re-raised when facing a single raise")
                row("Aggression factor", num(a.aggression), num(b.aggression), help: "Postflop (bets + raises) / calls")
                row("WTSD", pct(a.wtsd), pct(b.wtsd), help: "Went to showdown after seeing the flop")
                row("W$SD", pct(a.wsd), pct(b.wsd), help: "Won at showdown")
                row("C-bet", pct(a.cbet), pct(b.cbet), help: "Bet the flop as preflop aggressor")
                row("Fold to c-bet", pct(a.foldToCbet), pct(b.foldToCbet))
                row("Decisions", "\(a.decisions)", "\(b.decisions)")
                row("Invalid actions", "\(a.invalidActions)", "\(b.invalidActions)", help: "Unparseable or failed answers, defaulted to check/fold")
                if a.cost + b.cost > 0 || a.avgLatency != nil || b.avgLatency != nil {
                    row("Cost", Fmt.usd(a.cost), Fmt.usd(b.cost))
                    row("Avg latency", a.avgLatency.map { Fmt.duration($0) } ?? "–", b.avgLatency.map { Fmt.duration($0) } ?? "–")
                    row("Tokens in / out", "\(a.promptTokens) / \(a.completionTokens)", "\(b.promptTokens) / \(b.completionTokens)")
                }
            }
            .font(.callout.monospacedDigit())
        }
    }

    private func row(_ label: String, _ x: String, _ y: String, help: String? = nil) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).help(help ?? "")
            Text(x)
            Text(y)
        }
    }

    private func ci(_ v: Double, _ c: Double?) -> String { String(format: "%+.1f", v) + (c.map { String(format: " ± %.1f", $0) } ?? "") }
    private func pct(_ x: Double?) -> String { x.map { Fmt.pct($0, decimals: 0) } ?? "–" }
    private func num(_ x: Double?) -> String { x.map { String(format: "%.2f", $0) } ?? "–" }
}

// MARK: - Hand browser & replay

struct HandBrowser: View {
    let match: MatchRecord
    @Binding var selection: Int?
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", showdowns = "Showdowns", allIns = "All-ins", big = "Big pots", invalid = "Invalid"
        var id: String { rawValue }
    }

    private var hands: [HandRecord] {
        switch filter {
        case .all: return match.hands
        case .showdowns: return match.hands.filter { $0.result.showdown }
        case .allIns: return match.hands.filter { $0.result.allInEquity != nil }
        case .big: return match.hands.filter { $0.result.pot >= 40 * Chips.perBB }
        case .invalid: return match.hands.filter { $0.actions.contains { $0.meta?.fallback == true } }
        }
    }

    var body: some View {
        Panel("Hands", systemImage: "list.bullet.rectangle") {
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 460)
            HStack(alignment: .top, spacing: 14) {
                Table(hands, selection: $selection) {
                    TableColumn("#") { h in Text("\(h.number)").monospacedDigit() }.width(38)
                    TableColumn("BTN") { h in PlayerDot(player: h.seatPlayers[0]) }.width(34)
                    TableColumn(match.players[0].displayName) { h in ComboText(h.hole[h.seat(of: 0)], font: .callout.monospaced().weight(.semibold)) }.width(64)
                    TableColumn(match.players[1].displayName) { h in ComboText(h.hole[h.seat(of: 1)], font: .callout.monospaced().weight(.semibold)) }.width(64)
                    TableColumn("Board") { h in ComboText(h.board.compactText, font: .callout.monospaced()) }.width(min: 90, ideal: 120)
                    TableColumn("Pot") { h in Text(Chips.text(h.result.pot)).monospacedDigit() }.width(48)
                    TableColumn("A net") { h in
                        Text(String(format: "%+.1f", h.net(0))).monospacedDigit()
                            .foregroundStyle(h.net(0) > 0 ? Theme.positive : (h.net(0) < 0 ? Theme.negative : .secondary))
                    }.width(54)
                }
                .frame(width: 520, height: 560)
                if let n = selection, let h = match.hands.first(where: { $0.number == n }) {
                    HandReplayView(match: match, hand: h).id(h.number)
                } else {
                    EmptyStateView("Select a hand", systemImage: "play.rectangle", message: "Replay it step by step.")
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
        }
    }
}

struct HandReplayView: View {
    let match: MatchRecord
    let hand: HandRecord
    @State private var step = 0
    @State private var playing = false
    @State private var showText = false

    private var steps: [ReplayStep] { HandReplay.steps(hand, names: match.players.map(\.displayName)) }

    private func snapshot(_ steps: [ReplayStep]) -> TableSnapshot {
        let i = min(step, steps.count - 1)
        var state = steps[i].state
        if i == steps.count - 1 { state = HandState.finalState(of: hand) }
        var last: [Int: ActionRecord] = [:]
        for a in steps.prefix(i + 1).compactMap(\.action) where a.street == state.street || state.isComplete {
            last[hand.seatPlayers[a.seat]] = a
        }
        if let a = steps[i].action { last[hand.seatPlayers[a.seat]] = a }
        return TableSnapshot(hand: hand.number, deal: hand.deal, replica: hand.replica, state: state, seatPlayers: hand.seatPlayers, lastAction: last)
    }

    var body: some View {
        let steps = self.steps
        VStack(alignment: .leading, spacing: 10) {
            FeltTableView(snapshot: snapshot(steps), specs: match.players,
                          caption: "Hand #\(hand.number) · step \(min(step, steps.count - 1)) / \(steps.count - 1)")
                .frame(height: 400)
            HStack(spacing: 8) {
                Button { step = max(0, step - 1) } label: { Image(systemName: "backward.frame.fill") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                Button { step = min(steps.count - 1, step + 1) } label: { Image(systemName: "forward.frame.fill") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Slider(value: Binding(get: { Double(step) }, set: { step = Int($0.rounded()) }), in: 0...Double(max(1, steps.count - 1)), step: 1)
                Toggle("Text", isOn: $showText).toggleStyle(.button)
            }
            .controlSize(.small)
            let cur = steps[min(step, steps.count - 1)]
            VStack(alignment: .leading, spacing: 4) {
                Text(cur.caption).font(.callout.weight(.semibold))
                if let m = cur.action?.meta {
                    if let r = m.reasoning, !r.isEmpty {
                        Text(r).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if m.fallback {
                        Label("Invalid or failed decision — defaulted. \(m.errorMessage ?? "")", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Theme.negative)
                    }
                    if m.latency > 0 || m.cost > 0 {
                        Text("\(Fmt.duration(m.latency)) · \(m.promptTokens)/\(m.completionTokens) tokens · \(Fmt.usd(m.cost))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    if !m.raw.isEmpty {
                        DisclosureGroup("Raw response\(m.raw.count > 1 ? "s (\(m.raw.count))" : "")") {
                            Text(m.raw.joined(separator: "\n\n— retry —\n\n")).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                    }
                    if let t = m.thinking, !t.isEmpty {
                        DisclosureGroup("Hidden reasoning") {
                            Text(t).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showText {
                let text = HandHistoryFormatter.format(hand, match: match, includeReasoning: true)
                ScrollView {
                    Text(text).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .contextMenu {
                    Button("Copy Hand History") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: playing) {
            guard playing else { return }
            if step >= steps.count - 1 { step = 0 }
            while playing && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 900_000_000)
                if step >= steps.count - 1 { playing = false; break }
                step += 1
            }
        }
    }
}
