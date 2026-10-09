import ArenaKit
import DesignSystem
import SolverKit
import SwiftUI

/// Root of the Arena section: live table, saved matches and leaderboard.
public struct ArenaHomeView: View {
    public init() {}

    @State private var store = ArenaStore.shared
    @State private var tab: Tab = .live
    @State private var showNew = false
    @State private var selectedMatch: String?

    enum Tab: String, CaseIterable, Identifiable {
        case live = "Live", matches = "Matches", leaderboard = "Leaderboard"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .live: return "play.circle"
            case .matches: return "rectangle.stack"
            case .leaderboard: return "trophy"
            }
        }
    }

    public var body: some View {
        Group {
            switch tab {
            case .live:
                if let live = store.live {
                    LiveMatchView(live: live)
                } else {
                    welcome
                }
            case .matches:
                MatchesView(store: store, selection: $selectedMatch)
            case .leaderboard:
                LeaderboardView(store: store)
            }
        }
        .navigationTitle("Arena")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { t in Label(t.rawValue, systemImage: t.icon).tag(t) }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleOnly)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showNew = true } label: { Label("New Match", systemImage: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New match (⌘N)")
            }
            ToolbarItem {
                Button { store.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Reload saved matches (⌘R)")
            }
        }
        .sheet(isPresented: $showNew) {
            NewMatchSheet(store: store)
        }
        .onChange(of: store.live?.status) { _, status in
            if let status, status != .running, let id = store.live?.id, store.matches.contains(where: { $0.id == id }) {
                selectedMatch = id
            }
        }
    }

    private var subtitle: String {
        if let l = store.live, l.isRunning { return "Live: \(l.title)" }
        return "\(store.matches.count) saved matches"
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            ZStack {
                Capsule()
                    .fill(RadialGradient(colors: [Theme.felt, Theme.feltDeep], center: .center, startRadius: 10, endRadius: 260))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                    .frame(width: 440, height: 200)
                HStack(spacing: -10) {
                    ForEach(["As", "Kh"], id: \.self) { c in
                        PlayingCardView(Card(c), width: 60)
                            .rotationEffect(.degrees(c == "As" ? -7 : 7), anchor: .bottom)
                    }
                }
            }
            VStack(spacing: 6) {
                Text("Heads-up arena").font(.largeTitle.weight(.semibold))
                Text("Pit language models and bots against each other in full no-limit hold'em matches.\nEvery deal is played twice with seats swapped, so luck cancels out.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { showNew = true } label: { Label("New Match", systemImage: "plus") }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                Button { quickBots() } label: { Label("Quick demo: TAG vs Random", systemImage: "bolt.fill") }
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
            if !store.hasAPIKey {
                Text("No OpenRouter key yet — bots work offline. Add a key in Settings (⌘,) to play LLMs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func quickBots() {
        try? store.start(config: MatchConfig(deals: 25, seed: UInt64.random(in: 1...99_999), concurrency: 1),
                         specs: [.bot(.tag), .bot(.random)], speed: .animate)
    }
}
