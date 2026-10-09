import DesignSystem
import SolverKit
import SwiftUI

/// Phase 1: game configuration.
struct SetupView: View {
    @Bindable var session: SolverSession
    @State private var rangePlayer = 0
    @State private var showBoardPicker = false

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    scenarioPanel
                    boardPanel
                    stacksPanel
                    BetSizeEditor(session: session)
                    solvePanel
                }
                .padding(16)
            }
            .frame(width: 400)
            .scrollContentBackground(.hidden)

            Divider()

            ScrollView {
                RangeEditorView(session: session, player: $rangePlayer)
                    .padding(20)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Scenario

    private var scenarioPanel: some View {
        Panel("Scenario", systemImage: "person.2.fill") {
            Picker("Scenario", selection: Binding(
                get: { session.scenarioID ?? "custom" },
                set: { id in if let s = Scenarios.named(id) { session.applyScenario(s) } else { session.scenarioID = nil } }
            )) {
                ForEach(Scenarios.every) { s in Text(s.name).tag(s.id) }
                Divider()
                Text("Custom").tag("custom")
            }
            .labelsHidden()

            if let s = session.scenario {
                Text(s.summary).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                nameField("OOP", text: $session.oopName, color: Theme.oop)
                nameField("IP", text: $session.ipName, color: Theme.ip)
            }
        }
    }

    private func nameField(_ title: String, text: Binding<String>, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField(title, text: text).textFieldStyle(.roundedBorder)
        }
    }

    // MARK: Board

    private var boardPanel: some View {
        Panel("Board", systemImage: "rectangle.grid.1x2") {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    showBoardPicker = true
                } label: {
                    BoardView(session.boardCards, slots: 5, width: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Choose board cards")
                .popover(isPresented: $showBoardPicker, arrowEdge: .trailing) {
                    BoardPickerView(session: session)
                }
                Spacer(minLength: 0)
                VStack(spacing: 6) {
                    Button("Edit…") { showBoardPicker = true }
                    Button {
                        session.randomFlop()
                    } label: {
                        Image(systemName: "dice")
                    }
                    .help("Random flop")
                }
                .controlSize(.small)
            }
            HStack {
                Text(streetDescription).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(session.config.board.isEmpty ? "—" : session.config.board)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var streetDescription: String {
        switch session.boardCards.count {
        case 3: return "Flop solve · large tree"
        case 4: return "Turn solve"
        case 5: return "River solve · instant"
        default: return "Select 3–5 cards"
        }
    }

    // MARK: Pot & stacks

    private var stacksPanel: some View {
        Panel("Pot & stacks", systemImage: "circle.grid.cross") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Starting pot").foregroundStyle(.secondary)
                    bbField($session.config.startingPot)
                }
                GridRow {
                    Text("Effective stack").foregroundStyle(.secondary)
                    bbField($session.config.effectiveStack)
                }
                GridRow {
                    Text("SPR").foregroundStyle(.secondary)
                    Text(session.config.startingPot > 0
                         ? String(format: "%.2f", session.config.effectiveStack / session.config.startingPot) : "–")
                        .monospacedDigit()
                }
            }
            .font(.callout)
        }
    }

    private func bbField(_ value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 90)
            Text("bb").foregroundStyle(.secondary)
        }
    }

    // MARK: Solve

    private var solvePanel: some View {
        Panel("Solve", systemImage: "bolt.fill") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Target exploitability").foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("", value: $session.targetExploitability, format: .number.precision(.fractionLength(0...3)))
                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).monospacedDigit()
                            .frame(width: 70)
                        Text("% pot").foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Max iterations").foregroundStyle(.secondary)
                    TextField("", value: $session.maxIterations, format: .number)
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).monospacedDigit()
                        .frame(width: 70)
                }
            }
            .font(.callout)

            EstimateView(session: session)

            if let problem = session.setupProblem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange)
            }

            Button {
                session.solve()
            } label: {
                Label("Solve", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
                    .font(.headline)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .disabled(!session.canSolve)
            .help("Build the game tree and start solving (⌘R)")
        }
    }
}

/// Live tree size estimate with memory warnings.
struct EstimateView: View {
    let session: SolverSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let e = session.estimate {
                HStack(alignment: .top) {
                    StatTile("Action nodes", value: e.stats.actionNodes.formatted())
                    StatTile("Memory", value: Fmt.bytes(e.memoryBytes), tint: memoryColor)
                    StatTile("Hands", value: e.hands.map(String.init).joined(separator: " / "))
                }
                memoryBar(e.memoryBytes)
                if session.memoryLevel != .ok {
                    Label(session.memoryLevel == .critical
                          ? "Exceeds 85% of physical memory — reduce bet sizes or ranges."
                          : "Uses over half of physical memory.",
                          systemImage: "memorychip")
                        .font(.caption).foregroundStyle(memoryColor)
                }
            } else if let err = session.estimateError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("Estimating tree…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(session.isEstimating ? 0.55 : 1)
        .animation(.easeOut(duration: 0.2), value: session.isEstimating)
    }

    private var memoryColor: Color {
        switch session.memoryLevel {
        case .ok: return .primary
        case .high: return .orange
        case .critical: return .red
        }
    }

    private func memoryBar(_ bytes: UInt64) -> some View {
        let f = min(1, Double(bytes) / Double(SolverSession.physicalMemory))
        return VStack(alignment: .leading, spacing: 3) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(session.memoryLevel == .ok ? Theme.accent : memoryColor)
                        .frame(width: max(3, g.size.width * f))
                    Rectangle().fill(.secondary).frame(width: 1).offset(x: g.size.width * 0.5)
                    Rectangle().fill(.red.opacity(0.7)).frame(width: 1).offset(x: g.size.width * 0.85)
                }
            }
            .frame(height: 5)
            Text("\(Fmt.pct(f)) of \(Fmt.bytes(SolverSession.physicalMemory)) RAM")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// Bet / raise sizes per street and player.
struct BetSizeEditor: View {
    @Bindable var session: SolverSession

    private var streets: [(String, WritableKeyPath<BetSizes, StreetSizes>)] {
        let all: [(String, WritableKeyPath<BetSizes, StreetSizes>)] = [("Flop", \.flop), ("Turn", \.turn), ("River", \.river)]
        let n = session.boardCards.count
        return Array(all.dropFirst(max(0, min(2, n - 3))))
    }

    var body: some View {
        Panel("Bet sizes", systemImage: "slider.horizontal.3") {
            HStack {
                Text("% of pot · “a” = all-in").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu("Preset") {
                    Button("Standard") { session.config.betSizes = .standard }
                    Button("Detailed") { session.config.betSizes = .detailed }
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
            }
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("\(session.oopName) bet").gridColumnAlignment(.leading)
                    Text("raise")
                    Text("\(session.ipName) bet")
                    Text("raise")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(streets, id: \.0) { name, kp in
                    GridRow {
                        Text(name).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        sizeField($session.config.betSizes[dynamicMember: kp.appending(path: \.oop.bet)])
                        sizeField($session.config.betSizes[dynamicMember: kp.appending(path: \.oop.raise)])
                        sizeField($session.config.betSizes[dynamicMember: kp.appending(path: \.ip.bet)])
                        sizeField($session.config.betSizes[dynamicMember: kp.appending(path: \.ip.raise)])
                    }
                }
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("All-in threshold").foregroundStyle(.secondary)
                    HStack {
                        Slider(value: $session.config.allinThreshold, in: 0.3...1, step: 0.01)
                        Text(Fmt.pct(session.config.allinThreshold, decimals: 0))
                            .monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                GridRow {
                    Text("Raise limit").foregroundStyle(.secondary)
                    Stepper(value: $session.config.raiseLimit, in: 0...6) {
                        Text("\(session.config.raiseLimit) per street").monospacedDigit()
                    }
                }
                GridRow {
                    Text("Add all-in").foregroundStyle(.secondary)
                    Toggle("Always offer an all-in", isOn: $session.config.addAllin)
                        .toggleStyle(.switch).controlSize(.small)
                }
            }
            .font(.callout)
        }
    }

    private func sizeField(_ text: Binding<String>) -> some View {
        TextField("–", text: text)
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospaced())
            .frame(minWidth: 52)
    }
}
