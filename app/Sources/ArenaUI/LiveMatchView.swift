import ArenaKit
import DesignSystem
import SwiftUI

struct LiveMatchView: View {
    @Bindable var live: LiveMatch
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    FeltTableView(snapshot: live.table, specs: live.specs, caption: caption)
                        .frame(height: 500)
                    ReasoningPanel(live: live)
                    Panel {
                        CumulativeChart(points: live.points, playerName: live.name(0), totalHands: live.config.totalHands)
                            .frame(height: 220)
                    }
                }
                .padding(20)
            }
            .frame(minWidth: 640, maxWidth: .infinity)
            Divider()
            sidebar
                .frame(width: 340)
        }
    }

    private var caption: String? {
        guard let h = live.table.hand else { return nil }
        var s = "Hand #\(h) · deal \(live.table.deal + 1)"
        if live.config.duplicate { s += live.table.replica == 0 ? " · A on button" : " · B on button (swapped)" }
        if let st = live.table.state { s += " · " + (st.isComplete ? "Finished" : st.street.name) }
        return s
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    PlayerDot(player: 0); Text(live.specs[0].displayName).font(.title3.weight(.semibold))
                    Text("vs").foregroundStyle(.secondary)
                    PlayerDot(player: 1); Text(live.specs[1].displayName).font(.title3.weight(.semibold))
                }
                HStack(spacing: 8) {
                    StatusBadge(status: live.status)
                    Text("\(live.config.deals) deals\(live.config.duplicate ? " × 2 duplicate" : "") · seed \(live.config.seed)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if live.isRunning {
                Picker("Speed", selection: $live.speed) {
                    ForEach(PlaySpeed.allCases) { s in Label(s.title, systemImage: s.icon).tag(s) }
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
                .help("Animate pauses briefly after every action; fast-forward plays at full speed")
                Button {
                    live.paused.toggle()
                } label: {
                    Label(live.paused ? "Resume" : "Pause", systemImage: live.paused ? "play.fill" : "pause.fill")
                }
                .keyboardShortcut(.space, modifiers: [])
                Button(role: .destructive) {
                    live.cancel()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: .command)
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                let p = live.progress
                ProgressView(value: Double(p?.handsDone ?? 0), total: Double(max(1, live.config.totalHands))) {
                    HStack {
                        Text("Hands").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(p?.handsDone ?? 0) / \(live.config.totalHands)").font(.caption.monospacedDigit())
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        StatTile("\(live.name(0)) net", value: Fmt.signedBB(p?.net[0] ?? 0, decimals: 1),
                                 tint: tint(p?.net[0] ?? 0))
                        StatTile("All-in EV", value: Fmt.signedBB(p?.evNet[0] ?? 0, decimals: 1))
                    }
                    GridRow {
                        StatTile("bb/100", value: rate(p))
                        StatTile("Cost", value: Fmt.usd((p?.cost[0] ?? 0) + (p?.cost[1] ?? 0)),
                                 caption: invalidCaption(p))
                    }
                }
            }
            .padding(16)
            Divider()
            EventLogView(log: live.log, live: live)
        }
        .background(.background.secondary)
    }

    private func tint(_ x: Double) -> Color { x > 0 ? Theme.positive : (x < 0 ? Theme.negative : .primary) }

    private func rate(_ p: MatchProgress?) -> String {
        guard let p, p.handsDone > 0 else { return "–" }
        return String(format: "%+.1f", p.net[0] / Double(p.handsDone) * 100)
    }

    private func invalidCaption(_ p: MatchProgress?) -> String? {
        guard let p, p.invalid[0] + p.invalid[1] > 0 else { return nil }
        return "\(p.invalid[0]) / \(p.invalid[1]) invalid"
    }
}

struct PlayerDot: View {
    let player: Int
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Circle().fill(ArenaPalette.player(player, scheme)).frame(width: 9, height: 9)
            .accessibilityLabel(player == 0 ? "Player A" : "Player B")
    }
}

struct StatusBadge: View {
    let status: MatchStatus
    var body: some View {
        let (text, color, icon): (String, Color, String) = {
            switch status {
            case .running: return ("Live", Theme.accent, "dot.radiowaves.left.and.right")
            case .completed: return ("Completed", Theme.positive, "checkmark.circle.fill")
            case .cancelled: return ("Stopped", .secondary, "stop.circle.fill")
            case .failed: return ("Failed", Theme.negative, "exclamationmark.triangle.fill")
            }
        }()
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// Latest reasoning from each player, expandable to the full text and hidden reasoning.
struct ReasoningPanel: View {
    let live: LiveMatch
    @State private var expanded = true

    var body: some View {
        Panel {
            DisclosureGroup(isExpanded: $expanded) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(0..<2, id: \.self) { p in column(p) }
                }
                .padding(.top, 8)
            } label: {
                Label("Thinking", systemImage: "brain").font(.headline)
            }
        }
    }

    private func column(_ p: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PlayerDot(player: p)
                Text(live.name(p)).font(.subheadline.weight(.semibold))
                Spacer()
                if let r = live.reasoning[p] { Text("hand #\(r.hand)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            ScrollView {
                Text(live.reasoning[p]?.text ?? (live.specs[p].kind == .llm ? "No reasoning yet." : "Bot rationale appears here."))
                    .font(.callout)
                    .foregroundStyle(live.reasoning[p] == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 96)
            if let t = live.reasoning[p]?.thinking, !t.isEmpty {
                DisclosureGroup("Hidden reasoning") {
                    ScrollView {
                        Text(t).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EventLogView: View {
    let log: [LogEntry]
    let live: LiveMatch
    @State private var follow = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Event log").font(.headline)
                Spacer()
                Toggle("Follow", isOn: $follow).toggleStyle(.switch).controlSize(.mini)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(log) { e in
                            LogRow(entry: e).id(e.id)
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
                .onChange(of: log.last?.id) { _, id in
                    guard follow, let id else { return }
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }
}

struct LogRow: View {
    let entry: LogEntry
    @State private var open = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                icon.frame(width: 14)
                if let p = entry.player { PlayerDot(player: p) }
                Text(entry.text)
                    .font(entry.kind == .hand ? .caption.weight(.semibold) : .caption)
                    .foregroundStyle(entry.kind == .error ? Theme.negative : .primary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                if entry.detail != nil {
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if let d = entry.detail, open || entry.kind == .hand {
                Text(d).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(.leading, 20)
            }
        }
        .padding(.vertical, 3)
        .padding(.top, entry.kind == .hand ? 8 : 0)
        .contentShape(Rectangle())
        .onTapGesture { if entry.detail != nil { open.toggle() } }
    }

    @ViewBuilder private var icon: some View {
        switch entry.kind {
        case .hand: Image(systemName: "suit.spade.fill").foregroundStyle(Theme.accent).font(.caption2)
        case .street: Image(systemName: "rectangle.stack").foregroundStyle(.secondary).font(.caption2)
        case .showdown: Image(systemName: "eye").foregroundStyle(.secondary).font(.caption2)
        case .result: Image(systemName: "trophy").foregroundStyle(Theme.gold).font(.caption2)
        case .error: Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.negative).font(.caption2)
        case .info: Image(systemName: "info.circle").foregroundStyle(.secondary).font(.caption2)
        case .action: Image(systemName: "arrow.right").foregroundStyle(.tertiary).font(.caption2)
        }
    }
}
