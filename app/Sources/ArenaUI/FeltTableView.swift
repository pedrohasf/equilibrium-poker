import ArenaKit
import DesignSystem
import SolverKit
import SwiftUI

/// The heads-up felt: player A always sits at the bottom and B at the top, so the
/// dealer button moves between them as seats swap in duplicate play.
struct FeltTableView: View {
    let snapshot: TableSnapshot
    let specs: [PlayerSpec]
    var caption: String?

    private var state: HandState? { snapshot.state }

    var body: some View {
        ZStack {
            tableSurface
            VStack(spacing: 0) {
                PlayerPlate(player: 1, snapshot: snapshot, spec: specs[1], edge: .top)
                Spacer(minLength: 6)
                betChip(player: 1)
                Spacer(minLength: 6)
                center
                Spacer(minLength: 6)
                betChip(player: 0)
                Spacer(minLength: 6)
                PlayerPlate(player: 0, snapshot: snapshot, spec: specs[0], edge: .bottom)
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 40)
        }
        .overlay(alignment: .topLeading) {
            if let caption {
                Text(caption)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.black.opacity(0.35), in: Capsule())
                    .padding(.top, 22).padding(.leading, 70)
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: snapshot)
    }

    private var tableSurface: some View {
        ZStack {
            Capsule()
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            Capsule()
                .inset(by: 12)
                .fill(RadialGradient(colors: [Theme.felt.opacity(1), Theme.feltDeep], center: .center, startRadius: 20, endRadius: 520))
            Capsule()
                .inset(by: 12)
                .strokeBorder(Color.black.opacity(0.5), lineWidth: 2)
            Capsule()
                .inset(by: 46)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1.2)
        }
    }

    private var center: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(0..<5, id: \.self) { i in
                    let shown = (state?.boardCount ?? 0) > i
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .frame(width: 50, height: 69)
                        if shown, let c = state?.runout[i] {
                            PlayingCardView(c, width: 50)
                                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.8)),
                                                        removal: .opacity))
                                .id("\(snapshot.hand ?? 0)-\(i)")
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Text("POT").font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(.white.opacity(0.55))
                Text("\(Chips.text(potShown)) bb")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(value: Double(potShown)))
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(Color.black.opacity(0.25), in: Capsule())
            if let r = snapshot.result, let eq = r.allInEquity {
                Text(String(format: "All-in equity  %@ %.0f%%  ·  %@ %.0f%%",
                            specs[snapshot.seatPlayers[0]].displayName, eq[0] * 100, specs[snapshot.seatPlayers[1]].displayName, eq[1] * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    /// Total pot including the current street's bets (also drawn in front of the players).
    private var potShown: Int {
        guard let s = state else { return 0 }
        return s.isComplete ? (s.result?.pot ?? s.pot) : s.pot
    }

    @ViewBuilder
    private func betChip(player: Int) -> some View {
        let seat = snapshot.seat(of: player)
        let amount = (state?.isComplete ?? true) ? 0 : (state?.streetContrib[seat] ?? 0)
        HStack(spacing: 6) {
            if amount > 0 {
                ChipStackIcon(seat: seat)
                Text("\(Chips.text(amount))")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(value: Double(amount)))
            }
        }
        .frame(height: 24)
        .padding(.horizontal, amount > 0 ? 10 : 0)
        .background(amount > 0 ? Color.black.opacity(0.28) : .clear, in: Capsule())
        .transition(.scale.combined(with: .opacity))
    }
}

/// Three stacked chips.
struct ChipStackIcon: View {
    let seat: Int
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(i == 2 ? Theme.gold : Theme.gold.opacity(0.7))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2])))
                    .frame(width: 14, height: 14)
                    .offset(y: CGFloat(-i) * 3)
            }
        }
        .frame(width: 16, height: 20)
    }
}

struct PlayerPlate: View {
    let player: Int
    let snapshot: TableSnapshot
    let spec: PlayerSpec
    let edge: VerticalEdge

    private var seat: Int { snapshot.seat(of: player) }
    private var state: HandState? { snapshot.state }
    private var folded: Bool { state?.folded[seat] ?? false }
    private var isWinner: Bool { snapshot.result?.winners.contains(seat) == true && snapshot.result?.winners.count == 1 }

    var body: some View {
        VStack(spacing: 8) {
            if edge == .bottom { bubble }
            HStack(spacing: 14) {
                if edge == .top { info; cards } else { cards; info }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isWinner ? AnyShapeStyle(Theme.gold.opacity(0.16)) : AnyShapeStyle(Color.black.opacity(0.38)))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isWinner ? Theme.gold.opacity(0.9) : (snapshot.thinking == player ? Theme.accent.opacity(0.8) : Color.white.opacity(0.08)),
                                  lineWidth: isWinner || snapshot.thinking == player ? 1.5 : 1)
            )
            if edge == .top { bubble }
        }
    }

    private var cards: some View {
        HStack(spacing: -12) {
            ForEach(Array((state?.hole[seat] ?? []).enumerated()), id: \.offset) { i, c in
                PlayingCardView(c, width: 46, dimmed: folded)
                    .rotationEffect(.degrees(i == 0 ? -5 : 5), anchor: .bottom)
                    .transition(.asymmetric(insertion: .scale(scale: 0.4).combined(with: .opacity).combined(with: .offset(y: edge == .top ? 40 : -40)),
                                            removal: .opacity))
            }
        }
        .id(snapshot.hand ?? -1)
        .frame(minWidth: 84, minHeight: 66)
    }

    private var info: some View {
        VStack(alignment: edge == .top ? .trailing : .leading, spacing: 3) {
            HStack(spacing: 6) {
                if edge == .bottom { dealerButton }
                Text(spec.displayName).font(.headline).foregroundStyle(.white).lineLimit(1)
                if edge == .top { dealerButton }
            }
            Text("\(spec.provider)\(spec.kind == .decision ? " · decision" : "") · \(seat == 0 ? "BTN/SB" : "BB")")
                .font(.caption).foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 6) {
                Text("\(Chips.text(state?.stacks[seat] ?? 0)) bb")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .contentTransition(.numericText(value: Double(state?.stacks[seat] ?? 0)))
                if let r = snapshot.result {
                    let n = Chips.bb(r.net[seat])
                    Text(Fmt.signedBB(n, decimals: 1))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(n > 0 ? Theme.positive : (n < 0 ? Theme.negative : .white.opacity(0.7)))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            if let r = snapshot.result, r.showdown, let cat = r.categories?[seat] {
                Text(cat).font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(minWidth: 150, alignment: edge == .top ? .trailing : .leading)
    }

    @ViewBuilder
    private var dealerButton: some View {
        if seat == 0 {
            Text("D")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
                .frame(width: 18, height: 18)
                .background(Circle().fill(.white))
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                .transition(.scale)
                .accessibilityLabel("Dealer button")
        }
    }

    @ViewBuilder
    private var bubble: some View {
        Group {
            if snapshot.thinking == player {
                HStack(spacing: 6) {
                    ThinkingDots()
                    Text("Deciding").font(.caption.weight(.medium))
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.black.opacity(0.4), in: Capsule())
            } else if let a = snapshot.lastAction[player], !(snapshot.result != nil && a.kind != .fold && snapshot.result?.showdown == true) {
                Text(ActionText.short(a))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(ActionColors.color(a), in: Capsule())
                    .overlay(alignment: .topTrailing) {
                        if a.meta?.fallback == true {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2).foregroundStyle(.yellow)
                                .offset(x: 6, y: -6)
                                .help("Invalid or failed decision — defaulted to check/fold")
                        }
                    }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .id("\(snapshot.hand ?? 0)-\(a.street.rawValue)-\(a.potAfter)")
            } else {
                Color.clear
            }
        }
        .frame(height: 26)
    }
}

enum ActionColors {
    static func color(_ a: ActionRecord) -> Color {
        if a.allIn && a.kind != .call { return Theme.allin }
        switch a.kind {
        case .fold: return Theme.fold
        case .check: return Theme.check
        case .call: return Theme.call
        case .bet, .raise:
            let frac = Double(a.to) / Double(max(1, a.potAfter - a.amount))
            return Theme.betRamp[min(Theme.betRamp.count - 1, max(0, Int(frac * 3)))]
        }
    }
}

struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25)) { ctx in
            let phase = Int(ctx.date.timeIntervalSinceReferenceDate * 4) % 3
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().frame(width: 5, height: 5).opacity(i == phase ? 1 : 0.35)
                }
            }
        }
    }
}
