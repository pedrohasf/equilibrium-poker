import ArenaKit
import DesignSystem
import SwiftUI

struct LeaderboardView: View {
    let store: ArenaStore
    @State private var sort = [KeyPathComparator(\LeaderboardEntry.rating, order: .reverse)]
    @State private var selection: String?

    private var rows: [LeaderboardEntry] { store.leaderboard.sorted(using: sort) }

    var body: some View {
        if store.leaderboard.isEmpty {
            EmptyStateView("No ratings yet", systemImage: "trophy",
                           message: "Play matches between different players (⌘N). Ratings are fitted on duplicate-pair results across all saved matches.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Panel {
                        Table(rows, selection: $selection, sortOrder: $sort) {
                            TableColumn("#") { e in
                                Text("\((store.leaderboard.firstIndex { $0.id == e.id } ?? 0) + 1)").monospacedDigit().foregroundStyle(.secondary)
                            }.width(26)
                            TableColumn("Player", value: \.id) { e in
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(e.spec.displayName).font(.body.weight(.medium))
                                        if e.spec.kind == .decision { DecisionBadge(mode: e.spec.mode) }
                                    }
                                    Text(e.spec.kind == .bot ? "built-in bot" : e.spec.model).font(.caption).foregroundStyle(.secondary)
                                }
                            }.width(min: 160, ideal: 220)
                            TableColumn("Rating", value: \.rating) { e in
                                Text(String(format: "%.0f", e.rating)).font(.body.weight(.semibold).monospacedDigit())
                            }.width(64)
                            TableColumn("bb/100", value: \.bb100) { e in
                                Text(String(format: "%+.1f", e.bb100) + (e.ci95.map { String(format: " ± %.1f", $0) } ?? ""))
                                    .monospacedDigit()
                            }.width(min: 100, ideal: 120)
                            TableColumn("All-in EV", value: \.evBB100) { e in
                                Text(String(format: "%+.1f", e.evBB100)).monospacedDigit().foregroundStyle(.secondary)
                            }.width(72)
                            TableColumn("Pairs W-L-T") { e in Text("\(e.wins)-\(e.losses)-\(e.ties)").monospacedDigit() }.width(96)
                            TableColumn("Hands", value: \.hands) { e in Text("\(e.hands)").monospacedDigit() }.width(56)
                            TableColumn("Matches", value: \.matches) { e in Text("\(e.matches)").monospacedDigit() }.width(58)
                            TableColumn("Invalid") { e in
                                Text(e.decisions > 0 ? Fmt.pct(Double(e.invalidActions) / Double(e.decisions), decimals: 1) : "–").monospacedDigit()
                            }.width(56)
                            TableColumn("Cost", value: \.cost) { e in Text(e.cost > 0 ? Fmt.usd(e.cost) : "–").monospacedDigit() }.width(64)
                        }
                        .frame(height: min(520, CGFloat(rows.count) * 34 + 40))
                    }
                    Panel("Win rate · bb/100 with 95% confidence", systemImage: "chart.dots.scatter") {
                        WinRateCIChart(entries: store.leaderboard)
                    }
                    Text("Rating: Bradley–Terry strengths on the Elo scale (mean 1500), where each match scores the share of big blinds a player won across its duplicate pairs (both seatings of one deal). A 400-point gap means the stronger player expects ≈ 91% of the money exchanged. bb/100 pools all pairs a player played; self-play matches are excluded.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
            }
        }
    }
}
