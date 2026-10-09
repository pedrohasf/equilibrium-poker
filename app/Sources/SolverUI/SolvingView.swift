import Charts
import DesignSystem
import SolverKit
import SwiftUI

/// Phase 2: live solve progress.
struct SolvingView: View {
    @Bindable var session: SolverSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let err = session.solveError {
                    Panel {
                        Label(err, systemImage: "exclamationmark.octagon.fill")
                            .foregroundStyle(.red)
                        Button("Back to setup") { session.phase = .setup }
                    }
                }
                statsRow
                Panel("Exploitability", systemImage: "chart.line.downtrend.xyaxis") {
                    ConvergenceChart(history: session.progressHistory, target: session.runTarget)
                        .frame(height: 300)
                }
                controls
            }
            .padding(24)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            if let cfg = session.solvedConfig {
                BoardView(Card.parseList(cfg.board) ?? [], slots: 5, width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(session.solvedName(0)) vs \(session.solvedName(1))")
                        .font(.title2.weight(.semibold))
                    Text("Pot \(Fmt.bb(cfg.startingPot)) · Stack \(Fmt.bb(cfg.effectiveStack))")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            statusBadge
        }
    }

    @ViewBuilder private var statusBadge: some View {
        if session.isPreparing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Building tree…").foregroundStyle(.secondary)
            }
        } else if session.isSolving {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Solving").foregroundStyle(.secondary)
            }
        } else if session.solveError == nil, session.latestProgress != nil {
            Label(reachedTarget ? "Target reached" : "Stopped", systemImage: reachedTarget ? "checkmark.seal.fill" : "pause.circle.fill")
                .foregroundStyle(reachedTarget ? Theme.positive : .secondary)
        }
    }

    private var reachedTarget: Bool {
        guard let p = session.latestProgress else { return false }
        return Double(p.exploitability) <= session.runTarget
    }

    private var statsRow: some View {
        Panel {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let p = session.latestProgress
                HStack(alignment: .top, spacing: 16) {
                    StatTile("Iteration", value: p.map { "\($0.iteration)" } ?? "–")
                    StatTile("Exploitability", value: p.map { exploitText($0.exploitability) } ?? "–",
                             caption: "target \(exploitText(Float(session.runTarget)))", tint: exploitTint)
                    StatTile("Elapsed", value: Fmt.duration(elapsed(at: ctx.date)))
                    StatTile("Speed", value: session.iterationsPerSecond.map { String(format: "%.1f it/s", $0) } ?? "–")
                    if let est = session.solver?.estimate {
                        StatTile("Tree", value: Fmt.bytes(est.memoryBytes),
                                 caption: "\(est.stats.actionNodes.formatted()) action nodes")
                    }
                }
            }
            ProgressView(value: targetProgress)
                .tint(Theme.accent)
            Text(progressCaption).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func elapsed(at date: Date) -> Double {
        if let start = session.runStartedAt { return session.runBaseElapsed + date.timeIntervalSince(start) }
        return session.latestProgress?.elapsed ?? 0
    }

    private var exploitTint: Color {
        reachedTarget ? Theme.positive : .primary
    }

    /// Progress toward the target on a log scale from the first measurement.
    private var targetProgress: Double {
        guard let first = session.progressHistory.first, let last = session.progressHistory.last else { return 0 }
        let a = log(Double(max(first.exploitability, 1e-6)))
        let b = log(Double(max(last.exploitability, 1e-6)))
        let t = log(max(session.runTarget, 1e-6))
        guard a > t else { return 1 }
        return max(0, min(1, (a - b) / (a - t)))
    }

    private var progressCaption: String {
        let p = Int(targetProgress * 100)
        return "\(p)% of the way to the target (log scale)"
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if session.isBusy {
                Button(role: .destructive) {
                    session.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill").frame(minWidth: 90)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            } else if session.solver != nil {
                Button {
                    session.phase = .results
                } label: {
                    Label("Browse results", systemImage: "square.grid.3x3.fill").frame(minWidth: 140)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .controlSize(.large)
                ContinueControls(session: session)
            }
            Spacer()
            Button("Edit setup") { session.phase = .setup }
                .disabled(session.isBusy)
        }
    }

    private func exploitText(_ x: Float) -> String { String(format: "%.3f%%", x) }
}

/// Inline controls for continuing a stopped solve.
struct ContinueControls: View {
    @Bindable var session: SolverSession

    var body: some View {
        HStack(spacing: 6) {
            Button {
                session.continueSolving()
            } label: {
                Label("Continue", systemImage: "forward.fill")
            }
            .buttonStyle(.glass)
            .disabled(!session.canContinue)
            Text("+").foregroundStyle(.secondary)
            TextField("", value: $session.continueIterations, format: .number)
                .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 60)
            Text("it, target").foregroundStyle(.secondary)
            TextField("", value: $session.targetExploitability, format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 56)
            Text("%").foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

/// Exploitability vs iteration on a log axis.
struct ConvergenceChart: View {
    let history: [SolveProgress]
    let target: Double

    var body: some View {
        if history.isEmpty {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4))
                Text("Waiting for the first exploitability check…").foregroundStyle(.secondary)
            }
        } else {
            Chart {
                ForEach(history, id: \.iteration) { p in
                    LineMark(x: .value("Iteration", Int(p.iteration)),
                             y: .value("Exploitability", max(Double(p.exploitability), 1e-4)))
                        .foregroundStyle(Theme.accent)
                        .interpolationMethod(.monotone)
                    AreaMark(x: .value("Iteration", Int(p.iteration)),
                             yStart: .value("Floor", yFloor),
                             yEnd: .value("Exploitability", max(Double(p.exploitability), 1e-4)))
                        .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.22), Theme.accent.opacity(0.0)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                }
                RuleMark(y: .value("Target", target))
                    .foregroundStyle(Theme.gold)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("target \(String(format: "%.3g", target))%")
                            .font(.caption2.monospacedDigit()).foregroundStyle(Theme.gold)
                    }
            }
            .chartYScale(domain: yFloor...yCeil, type: .log)
            .chartYAxisLabel("% of pot")
            .chartXAxisLabel("Iteration")
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let d = v.as(Double.self) { Text(String(format: "%.3g", d)).monospacedDigit() }
                    }
                }
            }
        }
    }

    private var yFloor: Double {
        let lo = history.map { Double($0.exploitability) }.min() ?? target
        return max(1e-4, min(lo, target) * 0.6)
    }

    private var yCeil: Double {
        let hi = history.map { Double($0.exploitability) }.max() ?? 1
        return max(hi * 1.4, target * 2)
    }
}
