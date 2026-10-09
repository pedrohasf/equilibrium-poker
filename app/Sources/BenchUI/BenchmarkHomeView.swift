import AppKit
import BenchKit
import DesignSystem
import OpenRouterKit
import SolverKit
import SwiftUI

/// Root of the decision-model benchmark section: suites on the left, the selected suite's lab on the right.
public struct BenchmarkHomeView: View {
    @State private var model = BenchLabModel()

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            SuiteSidebar(model: model)
                .frame(width: 260)
            Divider()
            Group {
                if let suite = model.suite {
                    switch model.tab {
                    case .overview: SuiteOverview(model: model, suite: suite)
                    case .run: RunPanel(model: model, suite: suite)
                    case .leaderboard: LeaderboardView(model: model, suite: suite)
                    case .decisions: DecisionExplorer(model: model, suite: suite)
                    }
                } else {
                    ContentUnavailableView {
                        Label("No benchmark suite", systemImage: "square.stack.3d.up.slash")
                    } description: {
                        Text("A suite is a fixed set of solved decisions. Generate one, then run decision models and baselines against it.")
                    } actions: {
                        Button("Generate Suite…") { model.showGenerateSheet = true }
                            .buttonStyle(.glassProminent)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $model.tab) {
                    ForEach(BenchTab.allCases) { t in
                        Label(t.title, systemImage: t.icon).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleOnly)
                .disabled(model.suite == nil)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.showGenerateSheet = true
                } label: {
                    Label("New Suite", systemImage: "plus.square.on.square")
                }
                .help("Generate a new benchmark suite (⇧⌘N)")
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button {
                    model.startBaselines()
                } label: {
                    Label("Run Baselines", systemImage: "cpu")
                }
                .help("Score the reference bots on this suite (no API calls)")
                .disabled(model.suite == nil || model.running)

                if model.running {
                    Button(role: .cancel) {
                        model.cancelRun()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop the run; answers so far are kept and the run resumes next time (⌘.)")
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button {
                        model.tab = .run
                    } label: {
                        Label("Run Decision Models", systemImage: "play.fill")
                    }
                    .help("Pick decision models and run the benchmark (⌘R)")
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.suite == nil)
                }
            }
        }
        .background {
            // ⌘1…⌘4 switch views.
            ForEach(Array(BenchTab.allCases.enumerated()), id: \.offset) { i, t in
                Button(t.title) { model.tab = t }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    .hidden()
            }
        }
        .sheet(isPresented: $model.showGenerateSheet) {
            GenerateSuiteSheet(model: model)
        }
        .onAppear { model.reload() }
    }
}

// MARK: - Sidebar

struct SuiteSidebar: View {
    @Bindable var model: BenchLabModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedSuiteId) {
                Section {
                    ForEach(model.suites) { s in
                        SuiteRow(suite: s, runCount: s.id == model.selectedSuiteId ? model.runs.count : nil)
                            .tag(s.id)
                            .contextMenu {
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([BenchStore.url(suite: s.id)])
                                }
                                Button("Copy Suite ID") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(s.id, forType: .string)
                                }
                                Divider()
                                Button("Delete Suite and Runs", role: .destructive) { model.deleteSuite(s.id) }
                            }
                    }
                } header: {
                    Text("Suites")
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if model.suites.isEmpty {
                    Text("No suites yet").font(.callout).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Button {
                    model.showGenerateSheet = true
                } label: {
                    Label("New Suite", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload suites and runs from disk")
            }
            .padding(10)
        }
    }
}

struct SuiteRow: View {
    let suite: BenchmarkSuite
    let runCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(suite.name).font(.callout.weight(.medium)).lineLimit(1)
            HStack(spacing: 6) {
                ForEach(Street.allCases.reversed()) { s in
                    if let n = suite.countByStreet[s] {
                        HStack(spacing: 3) {
                            Circle().fill(Viz.street(s)).frame(width: 6, height: 6)
                            Text("\(s.title) \(n)")
                        }
                    }
                }
                if let runCount, runCount > 0 { Text("· \(runCount) runs") }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            Text(suite.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}
