import BenchKit
import Charts
import DesignSystem
import SwiftUI

struct LeaderboardView: View {
    @Bindable var model: BenchLabModel
    let suite: BenchmarkSuite
    @State private var sortOrder = [KeyPathComparator(\ModelScore.score, order: .reverse)]
    @State private var selection: ModelScore.ID?
    @State private var breakdown: Breakdown = .street

    enum Breakdown: String, CaseIterable, Identifiable {
        case street, type
        var id: String { rawValue }
        var title: String { self == .street ? "By street" : "By decision type" }
    }

    private var rows: [ModelScore] { model.leaderboard.sorted(using: sortOrder) }
    /// API players (decision models + chat LLMs).
    private var llms: [ModelScore] { model.leaderboard.filter { !$0.isBaseline } }
    private var baselines: [ModelScore] { model.leaderboard.filter(\.isBaseline) }
    private var groups: [PlayerKind] {
        PlayerKind.allCases.sorted { $0.order < $1.order }.filter { k in model.leaderboard.contains { $0.kind == k } }
    }

    var body: some View {
        if model.leaderboard.isEmpty {
            ContentUnavailableView {
                Label("No results yet", systemImage: "trophy")
            } description: {
                Text("Run the baselines (no API needed) to calibrate the scale, then run models from the Run tab.")
            } actions: {
                Button("Run Baselines") { model.startBaselines() }
                Button("Choose Models…") { model.tab = .run }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headline
                    table
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                        Panel("GTO score", systemImage: "chart.bar.xaxis") {
                            ScoreChart(llms: llms, baselines: baselines)
                        }
                        Panel("Mixed vs. argmax EV loss", systemImage: "chart.bar.doc.horizontal") {
                            MixedVsArgmaxChart(rows: model.leaderboard.filter(\.hasDistribution))
                        }
                        Panel("EV loss breakdown", systemImage: "square.split.2x1") {
                            Picker("", selection: $breakdown) {
                                ForEach(Breakdown.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 260)
                            BreakdownChart(rows: model.leaderboard.filter { $0.model != Baseline.bestEV.id }, breakdown: breakdown, suite: suite)
                        }
                        Panel("Cost vs. score", systemImage: "dollarsign.circle") {
                            CostScoreChart(llms: llms)
                        }
                        Panel("Latency", systemImage: "stopwatch") {
                            LatencyChart(llms: llms)
                        }
                    }
                    definitions
                }
                .padding(20)
            }
        }
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Leaderboard").font(.title2.weight(.semibold))
                Text("\(suite.decisions.count) decisions · EV loss measured against the solved equilibrium, decision by decision")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                let text = BenchCLIExport.text(suite: suite, rows: rows)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Label("Copy as Text", systemImage: "doc.on.doc")
            }
        }
    }

    private var table: some View {
        Table(of: ModelScore.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Player", value: \.label) { r in
                HStack(spacing: 6) {
                    Text("\((model.leaderboard.firstIndex { $0.id == r.id } ?? 0) + 1)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                    Image(systemName: r.kind.icon).foregroundStyle(.secondary).font(.caption)
                    Text(r.label).lineLimit(1).foregroundStyle(r.isBaseline ? .secondary : .primary)
                    if r.isDecisionModel { DecisionBadge() }
                    if !r.isComplete {
                        Text("\(r.answered)/\(r.total)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 200, ideal: 260)
            TableColumn("GTO score", value: \.score) { r in
                HStack(spacing: 6) {
                    MiniBar(fraction: r.score / 100, tint: r.isBaseline ? Viz.reference : Viz.series1)
                        .frame(width: 44)
                    Text(BenchFmt.score(r.score)).fontWeight(.semibold)
                    Text("±\(String(format: "%.1f", r.overall.gtoScoreCI))").font(.caption).foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
            .width(min: 130, ideal: 150)
            TableColumn("EV loss", value: \.lossPot) { r in
                HStack(spacing: 4) {
                    Text(BenchFmt.pctPot(r.lossPot, decimals: 2))
                    Text("±\(BenchFmt.pctPot(r.overall.meanEVLossPotCI, decimals: 1))").font(.caption).foregroundStyle(.secondary)
                }
                .monospacedDigit()
                .help("Mean EV loss per decision, % of pot (95% CI)")
            }
            .width(min: 100, ideal: 120)
            TableColumn("bb/dec", value: \.lossBB) { r in Text(String(format: "%.3f", r.lossBB)).monospacedDigit() }
                .width(56)
            TableColumn("Best", value: \.accuracy) { r in Text(Fmt.pct(r.accuracy, decimals: 0)).monospacedDigit() }
                .width(44)
            TableColumn("GTO-ok", value: \.approved) { r in Text(Fmt.pct(r.approved, decimals: 0)).monospacedDigit() }
                .width(52)
            TableColumn("Blunders", value: \.blunders) { r in
                Text(Fmt.pct(r.blunders, decimals: 0)).monospacedDigit()
                    .foregroundStyle(r.blunders > 0.1 ? Viz.critical : .primary)
            }
            .width(60)
            TableColumn("Invalid", value: \.invalid) { r in
                Text(Fmt.pct(r.invalid, decimals: 0)).monospacedDigit().foregroundStyle(r.invalid > 0 ? Viz.serious : .secondary)
            }
            .width(52)
            Group {
                TableColumn("Mixed loss", value: \ModelScore.mixedLossSort) { r in
                    Text(r.overall.meanMixedEVLossPot.map { BenchFmt.pctPot($0, decimals: 2) } ?? "–").monospacedDigit()
                        .foregroundStyle(r.hasDistribution ? .primary : .secondary)
                        .help("EV loss if the player played its reported probabilities: Σ p(a)·loss(a), % pot")
                }
                .width(72)
                TableColumn("TV dist", value: \ModelScore.tvSort) { r in
                    Text(r.overall.meanTVDistance.map { String(format: "%.3f", $0) } ?? "–").monospacedDigit()
                        .foregroundStyle(r.hasDistribution ? .primary : .secondary)
                        .help("Total-variation distance ½Σ|p − GTO| to the equilibrium mix for hero's hand (0 = identical)")
                }
                .width(56)
                TableColumn("P(best)", value: \ModelScore.bestProbSort) { r in
                    Text(r.overall.meanBestActionProbability.map { Fmt.pct($0, decimals: 0) } ?? "–").monospacedDigit()
                        .foregroundStyle(r.hasDistribution ? .primary : .secondary)
                        .help("Calibration: mean probability on the best-EV action(s)" + (r.overall.meanConfidence.map { String(format: " · mean reported confidence %.2f", $0) } ?? ""))
                }
                .width(56)
            }
            Group {
                TableColumn("Latency", value: \ModelScore.meanLatency) { r in
                    Text(r.isBaseline ? "–" : Fmt.duration(r.meanLatency)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(60)
                TableColumn("Cost", value: \ModelScore.totalCost) { r in
                    Text(r.isBaseline ? "–" : Fmt.usd(r.totalCost)).monospacedDigit()
                        .help(r.isBaseline ? "" : "\(BenchFmt.tokens(r.promptTokens)) prompt · \(BenchFmt.tokens(r.completionTokens)) completion tokens (\(BenchFmt.tokens(r.reasoningTokens)) reasoning)")
                }
                .width(60)
            }
        } rows: {
            ForEach(groups, id: \.self) { kind in
                Section(kind.groupTitle) {
                    ForEach(rows.filter { $0.kind == kind }) { TableRow($0) }
                }
            }
        }
        .contextMenu(forSelectionType: ModelScore.ID.self) { ids in
            if let id = ids.first {
                Button("Browse Decisions") { model.tab = .decisions }
                Button("Delete Run", role: .destructive) { model.deleteRun(id) }
            }
        }
        .frame(height: CGFloat(min(rows.count + groups.count, 16)) * 28 + 34)
    }

    private var definitions: some View {
        Panel("How scores are computed", systemImage: "function") {
            VStack(alignment: .leading, spacing: 4) {
                def("GTO score", "mean over decisions of 1 − (best EV − chosen EV) / (best EV − worst EV), × 100. 100 = always a max-EV action; 0 = always the worst.")
                def("EV loss", "best EV − chosen EV for the hero's exact hand, in bb and as % of the pot at the decision; ± is a 95% confidence interval.")
                def("Best", "chosen action within \(String(format: "%.2g", Scoring.bestTolerance * 100))% of the pot of the best EV.")
                def("GTO-ok", "the equilibrium plays the chosen action at least \(Int(Scoring.approvedFrequency * 100))% of the time with this hand.")
                def("Blunder", "EV loss above \(Int(Scoring.blunderThreshold * 100))% of the pot.")
                def("Invalid", "no parseable legal action, an unknown decision key, or an API failure; scored as the worst action.")
                def("Mixed loss", "for players that report probabilities (decision models; sampled GTO uses its strategy): Σ p(a) · EV loss(a), % pot — the EV lost if the reported distribution were played instead of its top choice.")
                def("TV dist", "total-variation distance ½ Σ |p(a) − GTO(a)| between the reported distribution and the equilibrium strategy of the hero's hand; 0 = same mix, 1 = disjoint.")
                def("P(best)", "calibration: mean probability assigned to the best-EV action(s) (within the Best tolerance).")
            }
            .font(.callout)
        }
    }

    private func def(_ k: String, _ v: String) -> some View {
        Text("\(Text(k).fontWeight(.semibold))\(Text(" — " + v).foregroundStyle(.secondary))")
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Exposes the CLI's leaderboard text for "Copy as Text".
enum BenchCLIExport {
    static func text(suite: BenchmarkSuite, rows: [ModelScore]) -> String {
        BenchCLI.leaderboardText(suite: suite, rows: rows)
    }
}

struct MiniBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Viz.grid)
                Capsule().fill(tint).frame(width: max(2, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}

/// Tooltip bubble: value first (strong), label second.
struct ChartTooltip: View {
    let value: String
    let label: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.callout.monospacedDigit().weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let detail { Text(detail).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// Tracks the hovered category on a chart's y axis.
struct HoverY: ViewModifier {
    @Binding var hovered: String?

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let pt):
                            guard let frame = proxy.plotFrame else { return }
                            let origin = geo[frame].origin
                            hovered = proxy.value(atY: pt.y - origin.y, as: String.self)
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
    }
}

// MARK: - Charts

struct ScoreChart: View {
    let llms: [ModelScore]
    let baselines: [ModelScore]
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                LegendDot(PlayerKind.decisionModel.tint, "Decision model")
                LegendDot(PlayerKind.llm.tint, "Chat LLM")
                Text("bars with 95% CI").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Rectangle().fill(Viz.reference).frame(width: 12, height: 2)
                    Text("Baseline").font(.caption).foregroundStyle(.secondary)
                }
            }
            if llms.isEmpty {
                Text("Model results appear here. Baselines are drawn as reference lines.").font(.caption).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(llms) { r in
                    BarMark(x: .value("GTO score", r.score), y: .value("Model", r.shortLabel), height: .fixed(16))
                        .foregroundStyle(r.kind.tint.opacity(hovered == nil || hovered == r.shortLabel ? 1 : 0.45))
                        .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4))
                    RuleMark(xStart: .value("Low", max(0, r.score - r.overall.gtoScoreCI)),
                             xEnd: .value("High", min(100, r.score + r.overall.gtoScoreCI)),
                             y: .value("Model", r.shortLabel))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .foregroundStyle(.primary.opacity(0.7))
                        .annotation(position: .trailing, spacing: 6) {
                            if hovered == r.shortLabel {
                                ChartTooltip(value: "\(BenchFmt.score(r.score)) ± \(String(format: "%.1f", r.overall.gtoScoreCI))",
                                             label: r.label,
                                             detail: "EV loss \(BenchFmt.pctPot(r.lossPot, decimals: 2)) pot · n=\(r.answered)")
                            } else {
                                Text(BenchFmt.score(r.score)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                }
                ForEach(baselines) { b in
                    RuleMark(x: .value("Baseline", b.score))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(Viz.reference)
                        .annotation(position: .top, alignment: .center, spacing: 2) {
                            Text(b.label).font(.caption2).foregroundStyle(.secondary).fixedSize()
                        }
                }
            }
            .chartXScale(domain: 0...100)
            .chartXAxis {
                AxisMarks(values: [0, 25, 50, 75, 100]) { _ in
                    AxisGridLine().foregroundStyle(Viz.grid)
                    AxisValueLabel().foregroundStyle(.secondary)
                }
            }
            .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(.primary) } }
            .modifier(HoverY(hovered: $hovered))
            .frame(height: max(160, CGFloat(llms.count) * 30 + 50))
        }
    }
}

struct BreakdownChart: View {
    let rows: [ModelScore]
    let breakdown: LeaderboardView.Breakdown
    let suite: BenchmarkSuite
    @State private var hovered: String?

    struct Point: Identifiable {
        var model: String
        var group: String
        var value: Double
        var n: Int
        var id: String { model + group }
    }

    private var groups: [(String, Color)] {
        switch breakdown {
        case .street:
            return Street.allCases.reversed().filter { suite.countByStreet[$0] != nil }.map { ($0.title, Viz.street($0)) }
        case .type:
            return DecisionType.allCases.map { ($0.title, Viz.decisionType($0)) }
        }
    }

    private var points: [Point] {
        rows.flatMap { r -> [Point] in
            switch breakdown {
            case .street:
                return Street.allCases.reversed().compactMap { s in
                    r.byStreet[s.rawValue].map { Point(model: r.shortLabel, group: s.title, value: $0.meanEVLossPot * 100, n: $0.n) }
                }
            case .type:
                return DecisionType.allCases.compactMap { t in
                    r.byType[t.rawValue].map { Point(model: r.shortLabel, group: t.title, value: $0.meanEVLossPot * 100, n: $0.n) }
                }
            }
        }
    }

    @ChartContentBuilder
    private func mark(_ p: Point) -> some ChartContent {
        let dim = hovered != nil && hovered != p.model
        let label = String(format: "%.2f%%", p.value) + " · n=\(p.n)"
        BarMark(x: .value("EV loss % pot", p.value), y: .value("Model", p.model), height: .fixed(9))
            .foregroundStyle(by: .value("Group", p.group))
            .position(by: .value("Group", p.group), axis: .vertical)
            .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3))
            .opacity(dim ? 0.45 : 1)
            .annotation(position: .trailing, spacing: 3) {
                if hovered == p.model {
                    Text(label).font(.caption2.monospacedDigit()).foregroundStyle(.primary)
                }
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                ForEach(groups, id: \.0) { LegendDot($0.1, $0.0) }
                Spacer()
                Text("Mean EV loss, % pot — lower is better").font(.caption).foregroundStyle(.secondary)
            }
            Chart(points) { p in mark(p) }
            .chartForegroundStyleScale(domain: groups.map(\.0), range: groups.map(\.1))
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Viz.grid)
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%") } }.foregroundStyle(.secondary)
                }
            }
            .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(.primary) } }
            .modifier(HoverY(hovered: $hovered))
            .frame(height: max(160, CGFloat(rows.count) * CGFloat(groups.count) * 13 + CGFloat(rows.count) * 10 + 40))
        }
    }
}

struct CostScoreChart: View {
    let llms: [ModelScore]
    @State private var hovered: String?

    /// USD per 100 decisions, so partial runs compare fairly.
    private func cost(_ r: ModelScore) -> Double { max(1e-4, r.totalCost / Double(max(1, r.answered)) * 100) }

    private var useLog: Bool {
        let cs = llms.map(cost)
        guard let lo = cs.min(), let hi = cs.max() else { return false }
        return hi / lo > 20
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GTO score vs. USD per 100 decisions\(useLog ? " (log scale)" : "") — up and left is better")
                .font(.caption).foregroundStyle(.secondary)
            if llms.isEmpty {
                Text("No model runs yet.").font(.callout).foregroundStyle(.secondary).frame(height: 160)
            } else {
                chart
            }
        }
    }

    @ViewBuilder private var chart: some View {
        let base = Chart(llms) { r in
            PointMark(x: .value("USD / 100 decisions", cost(r)), y: .value("GTO score", r.score))
                .symbolSize(hovered == r.id ? 140 : 80)
                .foregroundStyle(r.kind.tint)
                .annotation(position: .top, spacing: 4) {
                    if hovered == r.id {
                        ChartTooltip(value: "\(BenchFmt.score(r.score)) · \(Fmt.usd(cost(r)))/100", label: r.label,
                                     detail: "total \(Fmt.usd(r.totalCost)) over \(r.answered) decisions")
                    } else {
                        Text(r.shortLabel).font(.caption2).foregroundStyle(.secondary).fixedSize()
                    }
                }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Viz.grid)
                AxisValueLabel().foregroundStyle(.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(Viz.grid)
                AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.usd(d)) } }.foregroundStyle(.secondary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let pt) = phase, let frame = proxy.plotFrame else { hovered = nil; return }
                        let origin = geo[frame].origin
                        // Nearest point within 24 pt.
                        var best: (String, CGFloat)?
                        for r in llms {
                            guard let p = proxy.position(for: (x: cost(r), y: r.score)) else { continue }
                            let d = hypot(p.x + origin.x - pt.x, p.y + origin.y - pt.y)
                            if d < 24 && d < (best?.1 ?? .infinity) { best = (r.id, d) }
                        }
                        hovered = best?.0
                    }
            }
        }
        .frame(height: 220)
        if useLog {
            base.chartXScale(type: .log)
        } else {
            base
        }
    }
}

struct LatencyChart: View {
    let llms: [ModelScore]
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mean seconds per decision (including retries)").font(.caption).foregroundStyle(.secondary)
            if llms.isEmpty {
                Text("No model runs yet.").font(.callout).foregroundStyle(.secondary).frame(height: 160)
            } else {
                Chart(llms.sorted { $0.meanLatency < $1.meanLatency }) { r in
                    BarMark(x: .value("Seconds", r.meanLatency), y: .value("Model", r.shortLabel), height: .fixed(14))
                        .foregroundStyle(r.kind.tint.opacity(hovered == nil || hovered == r.shortLabel ? 1 : 0.45))
                        .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4))
                        .annotation(position: .trailing, spacing: 4) {
                            Text(Fmt.duration(r.meanLatency)).font(.caption.monospacedDigit())
                                .foregroundStyle(hovered == r.shortLabel ? .primary : .secondary)
                        }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(Viz.grid)
                        AxisValueLabel().foregroundStyle(.secondary)
                    }
                }
                .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(.primary) } }
                .modifier(HoverY(hovered: $hovered))
                .frame(height: max(140, CGFloat(llms.count) * 28 + 30))
            }
        }
    }
}

/// Per player: EV loss of the top choice (argmax) next to the EV loss of playing the reported distribution.
struct MixedVsArgmaxChart: View {
    let rows: [ModelScore]
    @State private var hovered: String?

    struct Point: Identifiable {
        var model: String
        var metric: String
        var value: Double
        var id: String { model + metric }
    }

    private static let metrics: [(String, Color)] = [("Argmax", Viz.series1), ("Mixed", Viz.series2)]

    private var points: [Point] {
        rows.flatMap { r -> [Point] in
            guard let m = r.overall.meanMixedEVLossPot else { return [] }
            return [Point(model: r.shortLabel, metric: "Argmax", value: r.lossPot * 100),
                    Point(model: r.shortLabel, metric: "Mixed", value: m * 100)]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                ForEach(Self.metrics, id: \.0) { LegendDot($0.1, $0.0 == "Argmax" ? "Top choice played" : "Distribution played") }
                Spacer()
                Text("Mean EV loss, % pot — lower is better").font(.caption).foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                Text("Players that report action probabilities (decision models, sampled GTO) appear here.")
                    .font(.callout).foregroundStyle(.secondary).frame(height: 140)
            } else {
                Chart(points) { p in
                    BarMark(x: .value("EV loss % pot", p.value), y: .value("Player", p.model), height: .fixed(9))
                        .foregroundStyle(by: .value("Metric", p.metric))
                        .position(by: .value("Metric", p.metric), axis: .vertical)
                        .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3))
                        .opacity(hovered != nil && hovered != p.model ? 0.45 : 1)
                        .annotation(position: .trailing, spacing: 3) {
                            if hovered == p.model {
                                Text(String(format: "%.2f%%", p.value)).font(.caption2.monospacedDigit())
                            }
                        }
                }
                .chartForegroundStyleScale(domain: Self.metrics.map(\.0), range: Self.metrics.map(\.1))
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { v in
                        AxisGridLine().foregroundStyle(Viz.grid)
                        AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%g%%", d)) } }.foregroundStyle(.secondary)
                    }
                }
                .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(.primary) } }
                .modifier(HoverY(hovered: $hovered))
                .frame(height: max(140, CGFloat(rows.count) * 30 + 40))
            }
        }
    }
}
