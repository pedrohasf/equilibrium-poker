import ArenaKit
import DesignSystem
import LLMKit
import SwiftUI

struct NewMatchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: ArenaStore

    @AppStorage("arena.playerA") private var playerA = "bot:tag"
    @AppStorage("arena.playerB") private var playerB = "bot:random"
    @AppStorage("arena.deals") private var deals = 50
    @AppStorage("arena.seed") private var seed = 1
    @AppStorage("arena.concurrency") private var concurrency = 4
    @AppStorage("arena.duplicate") private var duplicate = true
    @AppStorage("arena.opponentStats") private var opponentStats = false
    @AppStorage("arena.effort") private var effort = ""
    @AppStorage("arena.animate") private var animate = true
    @State private var error: String?

    private var specA: PlayerSpec? { spec(playerA) }
    private var specB: PlayerSpec? { spec(playerB) }

    private func spec(_ id: String) -> PlayerSpec? {
        guard var s = PlayerSpec.parse(id) else { return nil }
        if s.kind == .llm && s.reasoningEffort == nil && !effort.isEmpty { s.reasoningEffort = effort }
        return s
    }

    private var needsKey: Bool { [specA, specB].contains { $0?.kind == .llm } && !store.hasAPIKey }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New match").font(.title2.weight(.semibold))
                Spacer()
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 10)

            if !store.hasAPIKey { keyBanner.padding(.horizontal, 20).padding(.bottom, 10) }

            HStack(alignment: .top, spacing: 14) {
                PlayerPicker(title: "Player A", player: 0, selection: $playerA, store: store)
                PlayerPicker(title: "Player B", player: 1, selection: $playerB, store: store)
            }
            .padding(.horizontal, 20)

            Form {
                Section {
                    LabeledContent("Deals") {
                        HStack {
                            TextField("", value: $deals, format: .number).frame(width: 70).multilineTextAlignment(.trailing)
                            Stepper("", value: $deals, in: 1...5000, step: 10).labelsHidden()
                            Text(duplicate ? "= \(deals * 2) hands" : "hands").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Toggle("Duplicate format (replay every deal with seats swapped)", isOn: $duplicate)
                    LabeledContent("Seed") {
                        HStack {
                            TextField("", value: $seed, format: .number.grouping(.never)).frame(width: 90).multilineTextAlignment(.trailing)
                            Button { seed = Int.random(in: 1...999_999) } label: { Image(systemName: "dice") }
                                .help("Random seed")
                        }
                    }
                    Stepper("Parallel deals: \(concurrency)", value: $concurrency, in: 1...16)
                }
                Section("LLM players") {
                    Picker("Reasoning effort", selection: $effort) {
                        Text("Provider default").tag("")
                        ForEach(["minimal", "low", "medium", "high"], id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    Toggle("Show running opponent stats in prompts", isOn: $opponentStats)
                    LabeledContent("Estimated cost") { Text(costText).monospacedDigit() }
                }
                Section("Playback") {
                    Toggle("Animate hands (slower; switch to fast-forward any time)", isOn: $animate)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: 380)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.negative).font(.callout)
                    .padding(.horizontal, 20)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start match") { start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(specA == nil || specB == nil || needsKey || deals < 1)
            }
            .padding(20)
        }
        .frame(width: 820)
        .task { await store.loadCatalog() }
    }

    private var keyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill").foregroundStyle(Theme.gold)
            VStack(alignment: .leading, spacing: 2) {
                Text("No OpenRouter API key").font(.callout.weight(.semibold))
                Text("Bot-vs-bot matches work without one. To pit language models against each other, add a key in Settings (⌘,).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink { Text("Open Settings…") }
        }
        .padding(12)
        .background(Theme.gold.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var costText: String {
        let hands = duplicate ? deals * 2 : deals
        let parts = [specA, specB].compactMap { $0 }.map { CostEstimate.usd(spec: $0, hands: hands, info: store.price(for: $0.model)) }
        if [specA, specB].allSatisfy({ $0?.kind != .llm }) { return "Free (bots only)" }
        if parts.contains(where: { $0 == nil }) { return store.catalog.isEmpty ? "Unknown (catalog not loaded)" : "Unknown pricing" }
        let total = parts.compactMap { $0 }.reduce(0, +)
        return "≈ \(Fmt.usd(total))  (\(hands) hands, ~\(String(format: "%.1f", CostEstimate.decisionsPerHand)) decisions per player per hand)"
    }

    private func start() {
        guard let a = specA, let b = specB else { return }
        let cfg = MatchConfig(deals: deals, seed: UInt64(max(0, seed)), concurrency: concurrency, duplicate: duplicate,
                              opponentStats: opponentStats)
        do {
            try store.start(config: cfg, specs: [a, b], speed: animate ? .animate : .fast)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Bot or model chooser with search over the live OpenRouter catalog and the saved roster.
struct PlayerPicker: View {
    let title: String
    let player: Int
    @Binding var selection: String
    let store: ArenaStore
    @State private var mode: Mode = .bots
    @State private var query = ""

    enum Mode: String, CaseIterable, Identifiable {
        case bots = "Bots", roster = "Roster", catalog = "All models"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PlayerDot(player: player)
                Text(title).font(.headline)
                Spacer()
                Text(PlayerSpec.parse(selection)?.displayName ?? selection)
                    .font(.callout.weight(.medium)).lineLimit(1).foregroundStyle(.secondary)
            }
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if mode != .bots {
                TextField("Search models", text: $query).textFieldStyle(.roundedBorder)
            }
            List(selection: Binding(get: { selection }, set: { if let v = $0 { selection = v } })) {
                switch mode {
                case .bots:
                    ForEach(BotKind.allCases, id: \.self) { b in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.title).font(.body.weight(.medium))
                            Text(b.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .tag("bot:\(b.rawValue)")
                    }
                case .roster:
                    ForEach(filtered(ModelRoster.saved), id: \.self) { m in modelRow(m).tag(m) }
                case .catalog:
                    if store.catalog.isEmpty {
                        Text(store.hasAPIKey ? (store.catalogError ?? "Loading catalog…") : "Add an API key to browse models.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(filtered(store.catalog.map(\.id)), id: \.self) { m in modelRow(m).tag(m) }
                }
            }
            .listStyle(.bordered)
            .frame(height: 210)
            .disabled(mode != .bots && !store.hasAPIKey)
        }
        .frame(maxWidth: .infinity)
        .onAppear { if PlayerSpec.parse(selection)?.kind == .llm { mode = .roster } }
    }

    private func filtered(_ ids: [String]) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? ids : ids.filter { $0.lowercased().contains(q) }
    }

    private func modelRow(_ id: String) -> some View {
        let info = store.price(for: id)
        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(id.split(separator: "/").last.map(String.init) ?? id).font(.body.weight(.medium))
                Text(id.split(separator: "/").first.map(String.init) ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let i = info, let pin = i.promptPricePerM, let pout = i.completionPricePerM {
                Text(String(format: "$%.2f / $%.2f", pin, pout)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help("USD per million input / output tokens")
            }
        }
    }
}
