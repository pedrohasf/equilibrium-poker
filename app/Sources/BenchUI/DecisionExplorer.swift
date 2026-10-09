import BenchKit
import DesignSystem
import SolverKit
import SwiftUI

/// One player's answer to a decision, scored.
struct Answer: Identifiable {
    let run: BenchmarkRun
    let result: DecisionResult
    let score: DecisionScore
    var id: String { run.id }
}

struct DecisionExplorer: View {
    @Bindable var model: BenchLabModel
    let suite: BenchmarkSuite

    @State private var street: Street?
    @State private var type: DecisionType?
    @State private var blundersOnly = false
    @State private var disagreementOnly = false
    @State private var search = ""

    private var answers: [String: [Answer]] {
        var out: [String: [Answer]] = [:]
        let byId = Dictionary(uniqueKeysWithValues: suite.decisions.map { ($0.id, $0) })
        for run in model.runs {
            for r in run.results {
                guard let d = byId[r.decisionId] else { continue }
                out[d.id, default: []].append(Answer(run: run, result: r, score: Scoring.score(d, choice: r.choice)))
            }
        }
        for k in out.keys {
            out[k]!.sort { ($0.run.kind == .llm ? 0 : 1, $0.score.evLoss) < ($1.run.kind == .llm ? 0 : 1, $1.score.evLoss) }
        }
        return out
    }

    private func filtered(_ answers: [String: [Answer]]) -> [Decision] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        return suite.decisions.filter { d in
            if let street, d.street != street { return false }
            if let type, d.decisionType != type { return false }
            let llm = (answers[d.id] ?? []).filter { $0.run.kind == .llm }
            if blundersOnly && !llm.contains(where: { $0.score.blunder }) { return false }
            if disagreementOnly && Set(llm.map { $0.score.choice ?? -1 }).count < 2 { return false }
            if !q.isEmpty {
                let hay = [d.id, d.heroCards, d.board.joined(), d.board.joined(separator: " "), d.scenarioName, d.heroPosition].joined(separator: " ").lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
    }

    var body: some View {
        let answers = self.answers
        let list = filtered(answers)
        VStack(spacing: 0) {
            filterBar(count: list.count)
            Divider()
            HSplitView {
                List(selection: $model.selectedDecisionId) {
                    ForEach(list) { d in
                        DecisionRow(decision: d, answers: answers[d.id] ?? []).tag(d.id)
                    }
                }
                .listStyle(.inset)
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                .overlay {
                    if list.isEmpty { Text("No decisions match the filters").font(.callout).foregroundStyle(.secondary) }
                }

                Group {
                    if let id = model.selectedDecisionId, let d = suite.decision(id) {
                        DecisionDetail(decision: d, answers: answers[d.id] ?? [])
                            .id(d.id)
                    } else {
                        ContentUnavailableView("Select a decision", systemImage: "rectangle.and.text.magnifyingglass",
                                               description: Text("See the spot, the equilibrium strategy and EVs for the hero's hand, and how every player answered."))
                    }
                }
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if model.selectedDecisionId == nil || suite.decision(model.selectedDecisionId!) == nil {
                model.selectedDecisionId = list.first?.id
            }
        }
    }

    private func filterBar(count: Int) -> some View {
        HStack(spacing: 12) {
            Picker("Street", selection: $street) {
                Text("All streets").tag(Street?.none)
                ForEach(Street.allCases.reversed().filter { suite.countByStreet[$0] != nil }) { Text($0.title).tag(Street?.some($0)) }
            }
            .frame(width: 140)
            Picker("Type", selection: $type) {
                Text("All types").tag(DecisionType?.none)
                ForEach(DecisionType.allCases) { Text($0.title).tag(DecisionType?.some($0)) }
            }
            .frame(width: 140)
            .labelsHidden()
            Toggle("Blunders", isOn: $blundersOnly).toggleStyle(.button)
                .help("Only decisions where some model lost more than \(Int(Scoring.blunderThreshold * 100))% of the pot")
            Toggle("Disagreement", isOn: $disagreementOnly).toggleStyle(.button)
                .help("Only decisions where models chose different actions")
            Spacer()
            Text("\(count) of \(suite.decisions.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            TextField("Filter: cards, board, scenario", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
        }
        .labelsHidden()
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct DecisionRow: View {
    let decision: Decision
    let answers: [Answer]

    var body: some View {
        let llm = answers.filter { $0.run.kind == .llm }
        let worst = llm.max { $0.score.evLoss < $1.score.evLoss }
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(decision.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Tag(decision.street.title, tint: Viz.street(decision.street))
                    Text(decision.heroPosition).font(.caption.weight(.semibold))
                    Text(decision.facingBet ? "facing \(BB.fmt(decision.toCall))" : "to act").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    ComboText(decision.heroCards, font: .callout.monospaced().weight(.semibold))
                    HStack(spacing: 1) {
                        ForEach(decision.boardCards, id: \.self) { CardText($0, font: .caption.monospaced()) }
                    }
                }
            }
            Spacer(minLength: 4)
            if !llm.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    let best = llm.filter(\.score.isBest).count
                    Text("\(best)/\(llm.count) best").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if let w = worst, w.score.evLoss > 0 {
                        let g = AnswerGrade(w.score)
                        Label(BenchFmt.pctPot(w.score.evLossPot), systemImage: g.icon)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(g == .blunder ? Viz.critical : .secondary)
                            .help("Worst model loss: \(w.run.label)")
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail

struct DecisionDetail: View {
    let decision: Decision
    let answers: [Answer]
    @State private var revealVillain = false
    @State private var showPrompt = false

    private var d: Decision { decision }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(d.id).font(.title3.monospaced().weight(.semibold))
                    Text(d.scenarioName).font(.title3).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(d.street.title) · \(d.decisionType.title)").font(.callout).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 14) {
                    SpotTable(decision: d, revealVillain: $revealVillain)
                        .frame(minWidth: 340)
                    Panel("Action", systemImage: "text.alignleft") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(d.preflopSummary).font(.callout).foregroundStyle(.secondary)
                            ForEach(Array(PromptBuilder.historyLines(d, names: d.positions).enumerated()), id: \.offset) { _, line in
                                Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                            Text("\(d.heroPosition) to act · pot \(BB.fmt(d.pot)) bb\(d.facingBet ? " · \(BB.fmt(d.toCall)) to call" : "")")
                                .font(.callout.weight(.semibold))
                        }
                    }
                    .frame(maxWidth: 360)
                }
                solverPanel
                answersPanel
                DisclosureGroup(isExpanded: $showPrompt) {
                    Text(PromptBuilder.system + "\n\n" + PromptBuilder.user(d))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                } label: {
                    Label("Prompt sent to models (v\(PromptBuilder.version))", systemImage: "text.bubble")
                }
            }
            .padding(18)
        }
    }

    private var solverPanel: some View {
        let infos = d.actions.map(\.actionInfo)
        let lo = d.worstEV, hi = d.bestEV
        return Panel("Equilibrium for \(d.heroCards)", systemImage: "function") {
            HStack(spacing: 16) {
                Text("Equity \(Fmt.pct(d.equity))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("EV at stake \(BenchFmt.pctPot(d.evSpread / d.pot)) pot").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("Solver exploitability \(String(format: "%.2f", d.exploitability))% pot").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            FrequencyBar(actions: infos, frequencies: d.strategy.map(Float.init), height: 14)
            HStack(spacing: 12) {
                ForEach(d.actions.indices, id: \.self) { i in
                    LegendDot(Theme.actionColor(infos, i), "\(d.actions[i].shortLabel) \(Fmt.pct(d.strategy[i], decimals: 0))")
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    Text("Action"); Text("GTO").gridColumnAlignment(.trailing); Text("EV").gridColumnAlignment(.trailing)
                    Text("EV loss").gridColumnAlignment(.trailing); Text("")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(d.actions.indices, id: \.self) { i in
                    GridRow {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.actionColor(infos, i)).frame(width: 3, height: 14)
                            Text(d.actions[i].detailedLabel)
                            if i == d.bestAction { Image(systemName: "star.fill").font(.caption2).foregroundStyle(Theme.gold).help("Highest EV") }
                        }
                        Text(Fmt.pct(d.strategy[i], decimals: 0))
                        Text(String(format: "%.2f bb", d.actionEVs[i]))
                        Text(d.evLoss(i) < 1e-6 ? "–" : "−" + BenchFmt.pctPot(d.evLoss(i) / d.pot))
                            .foregroundStyle(d.evLoss(i) / d.pot > Scoring.blunderThreshold ? Viz.critical : .secondary)
                        EVBar(value: d.actionEVs[i], lo: lo, hi: hi, tint: Theme.actionColor(infos, i))
                            .frame(width: 160, height: 8)
                    }
                    .font(.callout.monospacedDigit())
                }
            }
        }
    }

    private var answersPanel: some View {
        Panel("Answers", systemImage: "person.3.sequence") {
            if answers.isEmpty {
                Text("No player has answered this decision yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(answers) { a in
                AnswerRow(answer: a, decision: d)
                if a.id != answers.last?.id { Divider() }
            }
        }
    }
}

/// Bar from the worst to the best EV of the decision.
struct EVBar: View {
    let value: Double
    let lo: Double
    let hi: Double
    let tint: Color

    var body: some View {
        GeometryReader { g in
            let t = hi - lo > 1e-9 ? (value - lo) / (hi - lo) : 1
            ZStack(alignment: .leading) {
                Capsule().fill(Viz.grid)
                Capsule().fill(tint).frame(width: max(3, g.size.width * t))
            }
        }
        .help(String(format: "%.3f bb", value))
    }
}

struct AnswerRow: View {
    let answer: Answer
    let decision: Decision
    @State private var expanded = false

    var body: some View {
        let s = answer.score
        let r = answer.result
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: answer.run.kind == .baseline ? "cpu" : "sparkles").foregroundStyle(.secondary).frame(width: 14)
                Text(answer.run.label).font(.callout.weight(.medium)).lineLimit(1)
                    .foregroundStyle(answer.run.kind == .baseline ? .secondary : .primary)
                Spacer()
                ActionChip(actions: decision.actions, index: s.choice)
                    .frame(minWidth: 130, alignment: .leading)
                Text(s.evLoss < 1e-6 ? "0" : "−" + String(format: "%.2f bb", s.evLoss))
                    .font(.callout.monospacedDigit()).frame(width: 74, alignment: .trailing)
                Text(BenchFmt.pctPot(s.evLossPot)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
                GradeBadge(grade: AnswerGrade(s)).frame(width: 78, alignment: .leading)
            }
            if answer.run.kind == .llm {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let e = r.error { Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Viz.serious) }
                        if let reasoning = r.reasoning, !reasoning.isEmpty {
                            Text("Reasoning").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(reasoning).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Response").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(r.rawResponse ?? "(empty)").font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 8))
                } label: {
                    HStack(spacing: 12) {
                        Text("Reasoning & response")
                        Text("\(Fmt.duration(r.latency)) · \(BenchFmt.tokens(r.promptTokens + r.completionTokens)) tok · \(Fmt.usd(r.cost))")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// A miniature heads-up table: villain on top, board and pot in the middle, hero at the bottom.
struct SpotTable: View {
    let decision: Decision
    @Binding var revealVillain: Bool

    var body: some View {
        let d = decision
        VStack(spacing: 12) {
            seat(name: d.villainPosition, stack: d.stacks[1 - d.heroSeat], ip: d.heroSeat == 0, hero: false) {
                HStack(spacing: 4) {
                    if revealVillain, let cs = Card.parseList(d.villainCards) {
                        ForEach(cs, id: \.self) { PlayingCardView($0, width: 30) }
                    } else {
                        ForEach(0..<2, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 5).fill(Theme.feltDeep)
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.25), lineWidth: 1))
                                .frame(width: 30, height: 41)
                        }
                    }
                }
                .onTapGesture { revealVillain.toggle() }
                .help(revealVillain ? "Hide villain's sampled hand" : "Reveal villain's sampled hand (never shown to models)")
            }
            VStack(spacing: 6) {
                BoardView(d.boardCards, slots: 5, width: 40)
                Text("Pot \(BB.fmt(d.pot)) bb").font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                if d.facingBet {
                    Text("\(d.villainPosition) bet · \(BB.fmt(d.toCall)) to call").font(.caption.monospacedDigit()).foregroundStyle(Theme.gold)
                }
            }
            seat(name: d.heroPosition, stack: d.stacks[d.heroSeat], ip: d.heroIsIP, hero: true) {
                HStack(spacing: 4) {
                    ForEach(d.heroCardList, id: \.self) { PlayingCardView($0, width: 40) }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(RadialGradient(colors: [Theme.felt, Theme.feltDeep], center: .center, startRadius: 10, endRadius: 260))
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
    }

    private func seat<C: View>(name: String, stack: Double, ip: Bool, hero: Bool, @ViewBuilder cards: () -> C) -> some View {
        HStack(spacing: 10) {
            cards()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(name).font(.callout.weight(.bold))
                    if hero { Tag("Hero", tint: Theme.accent) }
                    Text(ip ? "IP" : "OOP").font(.caption2.weight(.semibold)).foregroundStyle(Theme.playerColor(ip ? 1 : 0))
                }
                Text("\(BB.fmt(stack)) bb behind").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .foregroundStyle(.white)
    }
}
