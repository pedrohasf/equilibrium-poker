import DesignSystem
import SolverKit
import SwiftUI

extension SolverSession {
    /// One session per app run, so switching sidebar sections keeps the solved tree.
    static let shared = SolverSession()
}

/// Root of the Solver section: setup → solving → results in one workspace.
public struct SolverWorkspaceView: View {
    @State private var session = SolverSession.shared
    @State private var showInspector = true

    public init() {}

    public var body: some View {
        content
            .navigationTitle("Solver")
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            .inspector(isPresented: inspectorBinding) {
                HandInspector(session: session)
                    .inspectorColumnWidth(min: 260, ideal: 310, max: 420)
            }
            .animation(.smooth(duration: 0.25), value: session.phase)
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .setup: SetupView(session: session)
        case .solving: SolvingView(session: session)
        case .results: ResultsView(session: session)
        }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(get: { showInspector && session.phase == .results },
                set: { if session.phase == .results { showInspector = $0 } })
    }

    private var subtitle: String {
        if let cfg = session.solvedConfig, session.phase != .setup {
            return "\(session.solvedName(0)) vs \(session.solvedName(1)) · \(cfg.board)"
        }
        return session.scenario?.name ?? "Custom spot"
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Phase", selection: $session.phase) {
                ForEach(SolverSession.Phase.allCases) { p in
                    Text(p.title).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .disabled(session.solvedConfig == nil)
            .help("Switch between setup, solve progress and results")
        }

        ToolbarItemGroup(placement: .navigation) {
            if session.phase == .results {
                Button("Back", systemImage: "chevron.left") { session.back() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(session.path.isEmpty)
                    .help("Previous node (⌘[)")
                Button("Start of tree", systemImage: "house") { session.toRoot() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(session.path.isEmpty)
                    .help("Back to the root (⌘↑)")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if session.isBusy {
                Button("Stop", systemImage: "stop.fill") { session.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop solving (⌘.)")
            } else {
                Button("Solve", systemImage: "play.fill") { session.solve() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!session.canSolve)
                    .help("Solve the current setup (⌘R)")
                if session.canContinue {
                    Button("Continue solving", systemImage: "forward.fill") { session.continueSolving() }
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                        .help("Run \(session.continueIterations) more iterations (⇧⌘R)")
                }
            }
            if session.phase == .results {
                Button("Inspector", systemImage: "sidebar.right") { showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help("Toggle hand inspector (⌥⌘I)")
            }
        }
    }
}
