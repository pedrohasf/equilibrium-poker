import BenchKit
import Charts
import DesignSystem
import SolverKit
import SwiftUI

// MARK: - Overview

struct SuiteOverview: View {
    @Bindable var model: BenchLabModel
    let suite: BenchmarkSuite

    private var spreads: [Double] { suite.decisions.map { $0.evSpread / max($0.pot, 1e-9) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                tiles
                HStack(alignment: .top, spacing: 16) {
                    Panel("Decisions by scenario", systemImage: "person.2") { scenarioChart }
                    Panel("EV at stake", systemImage: "scalemass") { spreadChart }
                }
                HStack(alignment: .top, spacing: 16) {
                    Panel("Parameters", systemImage: "slider.horizontal.3") { parameters }
                        .frame(maxWidth: 380)
                    Panel("Runs on this suite", systemImage: "list.bullet.rectangle") { runsList }
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(suite.name).font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                Text(suite.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Text("·").foregroundStyle(.tertiary)
                Text(suite.createdAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var tiles: some View {
        let facing = suite.decisions.filter(\.facingBet).count
        let sorted = spreads.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let exploit = suite.decisions.map(\.exploitability).reduce(0, +) / Double(max(1, suite.decisions.count))
        return Panel {
            HStack(spacing: 18) {
                StatTile("Decisions", value: "\(suite.decisions.count)", caption: "from \(suite.solves) solves")
                StatTile("Streets", value: Street.allCases.reversed().compactMap { s in suite.countByStreet[s].map { "\(s.title.prefix(1))\($0)" } }.joined(separator: " "),
                         caption: "decision street")
                StatTile("Facing a bet", value: Fmt.pct(Double(facing) / Double(max(1, suite.decisions.count)), decimals: 0),
                         caption: "\(facing) of \(suite.decisions.count)")
                StatTile("Median EV at stake", value: BenchFmt.pctPot(median), caption: "best − worst, % pot")
                StatTile("Solver accuracy", value: String(format: "%.2f%%", exploit), caption: "exploitability, % pot")
                StatTile("Generated in", value: Fmt.duration(suite.generationSeconds), caption: "seed \(suite.parameters.seed)")
            }
        }
    }

    private var scenarioChart: some View {
        let rows = Scenarios.all.compactMap { s in suite.countByScenario[s.id].map { (s.name, $0) } }
        return Chart(rows, id: \.0) { name, n in
            BarMark(x: .value("Decisions", n), y: .value("Scenario", name), height: .fixed(14))
                .foregroundStyle(Viz.series1)
                .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4))
                .annotation(position: .trailing, spacing: 4) {
                    Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Viz.grid)
                AxisValueLabel().foregroundStyle(.secondary)
            }
        }
        .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(.secondary) } }
        .frame(height: max(120, CGFloat(rows.count) * 26))
        .accessibilityLabel("Decisions per preflop scenario")
    }

    private var spreadChart: some View {
        // Histogram of (best − worst) EV as % of pot, 10% bins capped at 100%+.
        let bins = (0..<10).map { i -> (String, Int) in
            let lo = Double(i) * 0.1, hi = i == 9 ? Double.infinity : lo + 0.1
            return (i == 9 ? "90%+" : "\(i * 10)–\(i * 10 + 10)%", spreads.filter { $0 >= lo && $0 < hi }.count)
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text("How much EV separates the best and worst action, as % of pot. Larger = more discriminating.")
                .font(.caption).foregroundStyle(.secondary)
            Chart(bins, id: \.0) { label, n in
                BarMark(x: .value("EV at stake", label), y: .value("Decisions", n), width: .fixed(18))
                    .foregroundStyle(Viz.series1)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                    .annotation(position: .top, spacing: 2) {
                        if n > 0 { Text("\(n)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                    }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Viz.grid)
                    AxisValueLabel().foregroundStyle(.secondary)
                }
            }
            .chartXAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(.secondary).font(.caption2) } }
            .frame(height: 150)
        }
    }

    private var parameters: some View {
        let p = suite.parameters
        let rows: [(String, String)] = [
            ("Root streets", p.streets.map(\.title).joined(separator: ", ")),
            ("Scenarios", p.scenarioIds.isEmpty ? "All \(Scenarios.all.count)" : p.scenarioIds.joined(separator: ", ")),
            ("Seed", "\(p.seed)"),
            ("Min EV at stake", BenchFmt.pctPot(p.minEVSpread) + " pot"),
            ("Decisions per solve", "≤ \(p.decisionsPerSolve)"),
            ("Solve target", String(format: "%.2f%% pot · ≤ %d iterations", p.targetExploitability, p.maxIterations)),
            ("Tree", "Turn/river: 33% & 75% bets, 60% raise · all-in ≥ 67% of stack"),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(rows, id: \.0) { k, v in
                    GridRow {
                        Text(k).foregroundStyle(.secondary)
                        Text(v).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
            Text("Each decision is an exact equilibrium answer for its subgame. Earlier streets follow a synthetic line (check-through or a small bet and call) that sets pot and stacks; ranges stay the preflop ranges.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var runsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.runs.isEmpty {
                Text("No runs yet. Use Run Baselines in the toolbar to calibrate, then run decision models from the Run tab.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.runs) { run in
                let s = model.leaderboard.first { $0.id == run.id }
                HStack(spacing: 10) {
                    Image(systemName: run.kind.icon)
                        .foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.label).font(.callout.weight(.medium))
                        Text("\(run.results.count)/\(suite.decisions.count) answered · updated \(run.updatedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let s {
                        Text(BenchFmt.score(s.score)).font(.callout.monospacedDigit().weight(.semibold))
                        Text("score").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([BenchStore.url(run: run.id)]) }
                    Button("Delete Run", role: .destructive) { model.deleteRun(run.id) }
                }
                Divider()
            }
        }
    }
}

// MARK: - Generate sheet

struct GenerateSuiteSheet: View {
    @Bindable var model: BenchLabModel
    @Environment(\.dismiss) private var dismiss

    @State private var decisions = 60
    @State private var river = true
    @State private var turn = true
    @State private var flop = false
    @State private var scenarioIds: Set<String> = Set(Scenarios.all.map(\.id))
    @State private var seed = UInt64.random(in: 1...9999)
    @State private var minSpread = 0.02
    @State private var perSolve = 3
    @State private var target = 0.4
    @State private var concurrency = 2
    @State private var name = ""

    private var streets: [Street] { [river ? Street.river : nil, turn ? .turn : nil, flop ? .flop : nil].compactMap { $0 } }

    private var params: SuiteParameters {
        SuiteParameters(decisions: decisions, streets: streets,
                        scenarioIds: scenarioIds.count == Scenarios.all.count ? [] : Scenarios.all.map(\.id).filter(scenarioIds.contains),
                        seed: seed, minEVSpread: minSpread, targetExploitability: target, decisionsPerSolve: perSolve,
                        concurrency: concurrency)
    }

    /// Very rough: river ≈ 0.15 s, turn ≈ 0.8 s, flop ≈ 120 s per solve on a recent Mac.
    private var etaText: String {
        guard !streets.isEmpty else { return "Pick at least one street" }
        let perSolve: [Street: Double] = [.river: 0.15, .turn: 0.8, .flop: 120]
        let solves = Double(decisions) / Double(max(1, self.perSolve) ) * 1.3
        let t = streets.reduce(0) { $0 + perSolve[$1]! } / Double(streets.count) * solves / Double(max(1, min(concurrency, 2)))
        return "≈ \(Int(solves.rounded())) solves · about \(Fmt.duration(max(1, t)))"
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Optional"))
                    Stepper(value: $decisions, in: 6...1000, step: decisions < 60 ? 6 : 20) {
                        LabeledContent("Decisions") { Text("\(decisions)").monospacedDigit() }
                    }
                    LabeledContent("Seed") {
                        HStack {
                            TextField("Seed", value: $seed, format: .number.grouping(.never))
                                .frame(width: 90).multilineTextAlignment(.trailing)
                            Button { seed = UInt64.random(in: 1...9999) } label: { Image(systemName: "dice") }
                                .buttonStyle(.borderless).help("Random seed")
                        }
                    }
                } header: {
                    Text("Suite")
                } footer: {
                    Text("Same seed and parameters → same decisions.").font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("River", isOn: $river)
                    Toggle("Turn", isOn: $turn)
                    Toggle(isOn: $flop) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Flop")
                            if flop {
                                Label("Flop subgames take minutes each to solve; the tree is reduced to one bet size per street.",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(Viz.serious)
                            }
                        }
                    }
                } header: {
                    Text("Streets")
                }

                Section("Preflop scenarios") {
                    ForEach(Scenarios.all) { s in
                        Toggle(isOn: Binding(get: { scenarioIds.contains(s.id) },
                                             set: { if $0 { scenarioIds.insert(s.id) } else if scenarioIds.count > 1 { scenarioIds.remove(s.id) } })) {
                            HStack {
                                Text(s.name)
                                Spacer()
                                Text("\(BB.fmt(s.pot)) bb pot · SPR \(String(format: "%.1f", s.spr))")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    LabeledContent("Min EV at stake") {
                        HStack {
                            Slider(value: $minSpread, in: 0...0.1, step: 0.005).frame(width: 160)
                            Text(BenchFmt.pctPot(minSpread)).monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                    Stepper(value: $perSolve, in: 1...10) {
                        LabeledContent("Decisions per solve") { Text("≤ \(perSolve)").monospacedDigit() }
                    }
                    Picker("Solve accuracy", selection: $target) {
                        Text("0.25% pot").tag(0.25)
                        Text("0.4% pot").tag(0.4)
                        Text("0.75% pot").tag(0.75)
                    }
                    Stepper(value: $concurrency, in: 1...6) {
                        LabeledContent("Parallel solves") { Text("\(concurrency)").monospacedDigit() }
                    }
                } header: {
                    Text("Sampling")
                } footer: {
                    Text("Decisions where every action has nearly the same EV are skipped so the benchmark discriminates. Hands are dealt from both ranges and played along each hand's own GTO strategy to a random decision.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(model.generating)

            Divider()
            HStack(spacing: 12) {
                if model.generating, let p = model.generationProgress {
                    ProgressView(value: Double(p.decisions), total: Double(max(1, p.target)))
                        .frame(width: 160)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(p.decisions)/\(p.target) decisions · \(p.solvesDone) solves · \(Fmt.duration(p.elapsed))")
                            .font(.caption.monospacedDigit())
                        if let s = p.lastSpot { Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    }
                } else if let e = model.generationError {
                    Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Viz.critical).lineLimit(2)
                } else {
                    Text(etaText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.generating ? "Stop" : "Cancel") {
                    if model.generating { model.cancelGeneration() } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Generate") {
                    model.generate(params, name: name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(model.generating || streets.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 560, height: 680)
    }
}
