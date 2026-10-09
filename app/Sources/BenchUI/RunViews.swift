import BenchKit
import DesignSystem
import LLMKit
import SwiftUI

struct RunPanel: View {
    @Bindable var model: BenchLabModel
    let suite: BenchmarkSuite
    @State private var showCatalog = false

    private var totalEstimate: Double? {
        let ests = model.selectedModels.map { model.estimate(for: $0)?.usd }
        guard !ests.isEmpty, !ests.contains(where: { $0 == nil }) else { return nil }
        return ests.compactMap { $0 }.reduce(0, +)
    }

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !model.hasKey { keyPrompt }
                    rosterPanel
                    optionsPanel
                    startBar
                }
                .padding(18)
            }
            .frame(minWidth: 420, idealWidth: 480)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    livePanel
                }
                .padding(18)
            }
            .frame(minWidth: 380)
        }
        .sheet(isPresented: $showCatalog) { CatalogSheet(model: model) }
        .task { await model.loadCatalog() }
    }

    private var keyPrompt: some View {
        Panel {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key.horizontal.fill").font(.title2).foregroundStyle(Theme.gold)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add your OpenRouter key").font(.headline)
                    Text("Model runs call OpenRouter. Paste a key in Settings (⌘,) — it is stored in your keychain. Baselines run locally without a key.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    SettingsLink { Text("Open Settings…") }
                }
            }
        }
    }

    private var rosterPanel: some View {
        let ids = model.roster(for: model.modelGroup)
        return Panel("Models", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 0) {
                Picker("", selection: $model.modelGroup) {
                    ForEach(ModelGroup.allCases) { g in
                        let n = model.roster(for: g).filter(model.selectedModels.contains).count
                        Text(n > 0 ? "\(g.title) · \(n)" : g.title).tag(g)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.bottom, 8)
                Text(model.modelGroup == .decision
                     ? "System One decision models read a JSON state of the spot and answer one typed choice question with a probability for every legal action. Output is free; you pay for input tokens only."
                     : "Chat LLMs read a text prompt, reason, and reply with an action number. Shown as a comparison group.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
                HStack {
                    Text("\(model.selectedModels.count) selected in total").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("All") { model.selectedModels.formUnion(ids) }.buttonStyle(.borderless)
                    Button("None") { model.selectedModels.subtract(ids) }.buttonStyle(.borderless)
                    Button {
                        showCatalog = true
                    } label: {
                        Label("Add from Catalog…", systemImage: "plus")
                    }
                    .disabled(!model.hasKey)
                }
                .font(.caption)
                .padding(.bottom, 6)
                if ids.isEmpty {
                    Text(model.modelGroup == .decision ? "No decision models on the roster are in the live catalog. Add some from the catalog."
                         : "No chat models on the roster.")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
                }
                ForEach(ids, id: \.self) { id in
                    rosterRow(id)
                    Divider()
                }
                if model.modelGroup == .decision, model.catalogState == .loaded, !model.missingDecisionModels.isEmpty {
                    Text("Hidden (not in the live catalog): \(model.missingDecisionModels.joined(separator: ", "))")
                        .font(.caption2).foregroundStyle(.secondary).padding(.top, 6)
                }
                if case .failed(let e) = model.catalogState {
                    Label("Catalog unavailable: \(e)", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                }
            }
        }
    }

    private func rosterRow(_ id: String) -> some View {
        let info = model.modelInfo(id)
        let isDecision = model.isDecisionModel(id)
        let runId = model.runId(for: id, suite: suite)
        let done = model.runs.first { $0.id == runId }?.results.count ?? 0
        let est = model.selectedModels.contains(id) ? model.estimate(for: id) : nil
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { model.selectedModels.contains(id) },
                                     set: { if $0 { model.selectedModels.insert(id) } else { model.selectedModels.remove(id) } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(info?.name ?? id).font(.callout.weight(.medium)).lineLimit(1)
                    if isDecision { DecisionBadge() }
                }
                HStack(spacing: 6) {
                    Text(id).font(.caption.monospaced())
                    if model.catalogState == .loaded && info == nil {
                        Label("not in catalog", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(Viz.serious)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                if let info {
                    if isDecision {
                        Text("\(BenchFmt.price(info.promptPrice)) in · output free")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .help("USD per million input tokens; decision models don't bill output")
                    } else {
                        Text("\(BenchFmt.price(info.promptPrice)) / \(BenchFmt.price(info.completionPrice))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .help("USD per million prompt / completion tokens")
                    }
                }
                if done > 0 {
                    Text(done >= suite.decisions.count ? "complete" : "\(done)/\(suite.decisions.count) — resumes")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if let est, let usd = est.usd {
                    Text("est. \(Fmt.usd(usd))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Remove from Roster", role: .destructive) { model.removeFromRoster(id) }
        }
    }

    private var optionsPanel: some View {
        Panel("Options", systemImage: "slider.horizontal.3") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                if model.modelGroup == .chat || model.selectedChatCount > 0 {
                    GridRow {
                        Text("Reasoning effort").foregroundStyle(.secondary)
                        Picker("", selection: $model.reasoningEffort) {
                            Text("Provider default").tag(String?.none)
                            ForEach(["minimal", "low", "medium", "high"], id: \.self) { Text($0.capitalized).tag(String?.some($0)) }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        .help("Chat LLMs only; decision models have no reasoning setting")
                    }
                }
                GridRow {
                    Text("Concurrent requests").foregroundStyle(.secondary)
                    Stepper(value: $model.concurrency, in: 1...32) { Text("\(model.concurrency)").monospacedDigit() }
                }
                GridRow {
                    Text("Decisions").foregroundStyle(.secondary)
                    Picker("", selection: $model.decisionLimit) {
                        Text("All \(suite.decisions.count)").tag(Int?.none)
                        ForEach([5, 10, 20, 40].filter { $0 < suite.decisions.count }, id: \.self) { Text("First \($0)").tag(Int?.some($0)) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }
            .font(.callout)
            Text(model.modelGroup == .decision
                 ? "Runs are saved as they go and resume where they stopped. Decision models get the JSON state v\(DecisionStateBuilder.version) (see Decisions → State sent)."
                 : "Runs are saved as they go and resume where they stopped. A different reasoning effort is a separate run.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var startBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Estimated cost").font(.caption).foregroundStyle(.secondary)
                if let t = totalEstimate {
                    Text(Fmt.usd(t)).font(.title3.monospacedDigit().weight(.semibold))
                } else {
                    Text(model.selectedModels.isEmpty ? "–" : "unknown (prices unavailable)").font(.callout).foregroundStyle(.secondary)
                }
            }
            .help("Decision models: estimated input tokens × input price (output is free). Chat LLMs: prompt length × price + an assumed completion budget per decision (~\(CostEstimator.completionTokens(reasoningEffort: model.reasoningEffort)) tokens at this reasoning effort).")
            Spacer()
            if model.running {
                Button(role: .cancel) { model.cancelRun() } label: { Label("Stop", systemImage: "stop.fill") }
                    .controlSize(.large)
            } else {
                Button {
                    model.startModels()
                } label: {
                    Label("Run \(model.selectedModels.count) Model\(model.selectedModels.count == 1 ? "" : "s")", systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(model.selectedModels.isEmpty || !model.hasKey)
            }
        }
    }

    private var livePanel: some View {
        Panel("Progress", systemImage: "waveform.path.ecg") {
            if let e = model.runError {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Viz.critical)
            }
            if model.liveOrder.isEmpty {
                Text("Live progress for each model appears here: decisions answered, running GTO score and cost so far.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.liveOrder, id: \.self) { id in
                if let p = model.live[id] { LiveRow(p: p, running: model.running) }
            }
        }
    }
}

struct LiveRow: View {
    let p: RunProgress
    let running: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: p.kind.icon).foregroundStyle(.secondary)
                Text(p.label).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                if p.done >= p.total {
                    Label("Done", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Viz.good)
                } else if running {
                    ProgressView().controlSize(.mini)
                }
            }
            ProgressView(value: p.fraction).tint(Viz.series1)
            HStack(spacing: 16) {
                stat("answered", "\(p.done)/\(p.total)")
                stat("GTO score", p.done == 0 ? "–" : BenchFmt.score(p.score))
                stat("EV loss", p.done == 0 ? "–" : BenchFmt.pctPot(p.evLossPot) + " pot")
                stat("invalid", "\(p.invalid)")
                if let m = p.mixedEVLossPot, p.kind != .baseline { stat("mixed loss", BenchFmt.pctPot(m) + " pot") }
                if p.kind.isModel { stat("cost", Fmt.usd(p.cost)) }
            }
            if let e = p.lastError {
                Text(e).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(e)
            }
        }
        .padding(.vertical, 6)
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(v).font(.callout.monospacedDigit().weight(.semibold)).contentTransition(.numericText())
            Text(k).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Catalog

struct CatalogSheet: View {
    @Bindable var model: BenchLabModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var group: ModelGroup?

    private var filtered: [ModelInfo] {
        let q = query.lowercased()
        let g = group ?? model.modelGroup
        return model.catalog.filter { m in
            (m.isDecisionModel == (g == .decision)) && (q.isEmpty || m.id.lowercased().contains(q) || m.name.lowercased().contains(q))
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.catalogState {
                case .loading, .idle:
                    ProgressView("Loading OpenRouter catalog…").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let e):
                    ContentUnavailableView("Catalog unavailable", systemImage: "wifi.exclamationmark", description: Text(e))
                case .loaded:
                    VStack(spacing: 0) {
                    Picker("", selection: Binding(get: { group ?? model.modelGroup }, set: { group = $0 })) {
                        ForEach(ModelGroup.allCases) { g in
                            Text("\(g.title) (\(model.catalog.filter { $0.isDecisionModel == (g == .decision) }.count))").tag(g)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 360)
                    .padding(8)
                    Table(filtered) {
                        TableColumn("Model") { m in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(m.name).lineLimit(1)
                                    if m.isDecisionModel { DecisionBadge() }
                                    if DecisionRoster.suggested.contains(m.id) {
                                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(Theme.gold).help("Suggested for poker benchmarking")
                                    }
                                }
                                Text(m.id).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        TableColumn("Context") { m in
                            Text(m.contextLength.map { BenchFmt.tokens($0) } ?? "–").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .width(70)
                        TableColumn("In $/M") { m in Text(BenchFmt.price(m.promptPrice)).monospacedDigit() }.width(64)
                        TableColumn("Out $/M") { m in
                            Text(m.isDecisionModel ? "free" : BenchFmt.price(m.completionPrice)).monospacedDigit()
                        }
                        .width(64)
                        TableColumn("") { m in
                            if model.isOnRoster(m.id) {
                                Image(systemName: "checkmark").foregroundStyle(Viz.good)
                            } else {
                                Button("Add") { model.addToRoster(m.id) }.buttonStyle(.borderless)
                            }
                        }
                        .width(44)
                    }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search models")
            .navigationTitle("OpenRouter models")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem {
                    Button { Task { await model.loadCatalog(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh catalog")
                }
            }
        }
        .frame(width: 720, height: 560)
        .task { await model.loadCatalog() }
    }
}
