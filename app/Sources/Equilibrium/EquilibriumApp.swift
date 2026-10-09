import ArenaUI
import BenchUI
import DesignSystem
import SolverKit
import SolverUI
import SwiftUI

@main
struct EquilibriumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Equilibrium", id: "main") {
            RootView()
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1440, height: 900)

        Settings {
            SettingsView()
                .frame(width: 560)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running as a bare SwiftPM executable: become a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Section: String, CaseIterable, Identifiable {
    case solver, benchmarks, arena

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solver: return "Solver"
        case .benchmarks: return "LLM Benchmarks"
        case .arena: return "Arena"
        }
    }

    var subtitle: String {
        switch self {
        case .solver: return "Postflop GTO"
        case .benchmarks: return "EV loss vs. GTO"
        case .arena: return "Heads-up matches"
        }
    }

    var icon: String {
        switch self {
        case .solver: return "function"
        case .benchmarks: return "chart.bar.xaxis"
        case .arena: return "suit.spade.fill"
        }
    }
}

struct RootView: View {
    @SceneStorage("section") private var section: Section = .solver

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { section }, set: { if let s = $0 { section = s } })) {
                SwiftUI.Section {
                    ForEach(Section.allCases) { s in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.title)
                                Text(s.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: s.icon)
                        }
                        .tag(s)
                        .padding(.vertical, 3)
                    }
                } header: {
                    HStack(spacing: 8) {
                        Image(systemName: "scale.3d").foregroundStyle(Theme.accent)
                        Text("Equilibrium").font(.headline)
                    }
                    .padding(.bottom, 6)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            switch section {
            case .solver: SolverWorkspaceView()
            case .benchmarks: BenchmarkHomeView()
            case .arena: ArenaHomeView()
            }
        }
    }
}
