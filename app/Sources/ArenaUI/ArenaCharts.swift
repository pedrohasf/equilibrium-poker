import ArenaKit
import Charts
import DesignSystem
import SwiftUI

/// Chart colours: categorical slots 1 (blue) and 2 (orange) of the validated reference palette,
/// stepped separately for light and dark surfaces (validator: all checks pass in both modes).
enum ArenaPalette {
    static func series1(_ scheme: ColorScheme) -> Color { scheme == .dark ? hex(0x3987E5) : hex(0x2A78D6) }
    static func series2(_ scheme: ColorScheme) -> Color { scheme == .dark ? hex(0xD95926) : hex(0xEB6834) }
    static func grid(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08) }

    /// Player identity colours (A = slot 1, B = slot 2).
    static func player(_ p: Int, _ scheme: ColorScheme) -> Color { p == 0 ? series1(scheme) : series2(scheme) }

    static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Player A's cumulative winnings and all-in-EV-adjusted winnings by hand.
struct CumulativeChart: View {
    let points: [CumulativePoint]
    let playerName: String
    /// Planned number of hands (fixes the x domain while a match is live).
    var totalHands: Int?
    @Environment(\.colorScheme) private var scheme
    @State private var selected: Int?

    /// Lines start at the origin (0 hands, 0 bb).
    private var series: [CumulativePoint] {
        points.isEmpty ? [] : [CumulativePoint(index: 0, hand: 0, net: 0, ev: 0)] + points
    }

    private var selectedPoint: CumulativePoint? {
        guard let s = selected else { return nil }
        return points.min { abs($0.index - s) < abs($1.index - s) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(playerName) · cumulative winnings").font(.subheadline.weight(.semibold))
                Spacer()
                legend
            }
            Chart {
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(Color.gray.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                ForEach(series) { p in
                    LineMark(x: .value("Hand", p.index), y: .value("bb", p.ev), series: .value("Series", "All-in EV"))
                        .foregroundStyle(ArenaPalette.series2(scheme))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    LineMark(x: .value("Hand", p.index), y: .value("bb", p.net), series: .value("Series", "Won"))
                        .foregroundStyle(ArenaPalette.series1(scheme))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if let last = points.last {
                    PointMark(x: .value("Hand", last.index), y: .value("bb", last.net))
                        .symbolSize(70)
                        .foregroundStyle(ArenaPalette.series1(scheme))
                }
                if let p = selectedPoint {
                    RuleMark(x: .value("Hand", p.index))
                        .foregroundStyle(Color.gray.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            tooltip(p)
                        }
                }
            }
            .chartXSelection(value: $selected)
            .chartXScale(domain: 0...max(1, totalHands ?? 0, points.last?.index ?? 0))
            .chartXAxisLabel("Hands played", alignment: .trailing)
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ArenaPalette.grid(scheme))
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) bb").monospacedDigit() } }
                }
            }
            .chartXAxis {
                AxisMarks { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ArenaPalette.grid(scheme))
                    AxisValueLabel()
                }
            }
            .chartPlotStyle { $0.clipped() }
            .overlay {
                if points.isEmpty {
                    Text("Waiting for the first hand…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Cumulative winnings chart")
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            LineKey(color: ArenaPalette.series1(scheme), label: "Won")
            LineKey(color: ArenaPalette.series2(scheme), label: "All-in EV")
        }
    }

    private func tooltip(_ p: CumulativePoint) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Hand #\(p.hand)").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                LineKey(color: ArenaPalette.series1(scheme), label: nil)
                Text(Fmt.signedBB(p.net, decimals: 1)).font(.caption.weight(.semibold).monospacedDigit())
                Text("won").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                LineKey(color: ArenaPalette.series2(scheme), label: nil)
                Text(Fmt.signedBB(p.ev, decimals: 1)).font(.caption.weight(.semibold).monospacedDigit())
                Text("all-in EV").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A short stroke of the series colour used as legend / tooltip key.
struct LineKey: View {
    let color: Color
    let label: String?

    var body: some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 14, height: 2.5)
            if let label { Text(label).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// bb/100 with 95% confidence intervals, one row per player.
struct WinRateCIChart: View {
    let entries: [LeaderboardEntry]
    @Environment(\.colorScheme) private var scheme
    @State private var selected: String?

    var body: some View {
        let mark = ArenaPalette.series1(scheme)
        Chart {
            RuleMark(x: .value("Zero", 0))
                .foregroundStyle(Color.gray.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(entries) { e in
                if let ci = e.ci95 {
                    RuleMark(xStart: .value("Low", e.bb100 - ci), xEnd: .value("High", e.bb100 + ci), y: .value("Player", e.spec.displayName))
                        .foregroundStyle(mark.opacity(selected == nil || selected == e.spec.displayName ? 0.45 : 0.2))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                PointMark(x: .value("bb/100", e.bb100), y: .value("Player", e.spec.displayName))
                    .symbolSize(selected == e.spec.displayName ? 110 : 70)
                    .foregroundStyle(mark)
                    .annotation(position: .trailing, spacing: 8) {
                        if selected == e.spec.displayName {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(Fmt.signedBB(e.bb100, decimals: 1).replacingOccurrences(of: " bb", with: "")) bb/100")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                if let ci = e.ci95 {
                                    Text("95% CI ± \(String(format: "%.1f", ci))").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .padding(6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
            }
        }
        .chartYSelection(value: $selected)
        .chartYAxis {
            AxisMarks { _ in AxisValueLabel(centered: true) }
        }
        .chartXAxis {
            AxisMarks { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ArenaPalette.grid(scheme))
                AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))").monospacedDigit() } }
            }
        }
        .chartXAxisLabel("bb/100 · dot = estimate, bar = 95% CI", alignment: .center)
        .frame(height: max(120, CGFloat(entries.count) * 34 + 50))
        .accessibilityLabel("Win rate with confidence intervals")
    }
}
