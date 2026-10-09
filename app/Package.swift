// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The Rust solver core is built by `make core` into ../core/target/release.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let rustLibDir = "\(packageDir)/../core/target/release"

let package = Package(
    name: "Equilibrium",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Equilibrium", targets: ["Equilibrium"]),
        .executable(name: "eqbench", targets: ["eqbench"]),
    ],
    targets: [
        .target(
            name: "CGTOCore",
            path: "Sources/CGTOCore",
            linkerSettings: [
                .unsafeFlags(["-L\(rustLibDir)"]),
                .linkedLibrary("gto_core"),
            ]
        ),
        .target(name: "SolverKit", dependencies: ["CGTOCore"]),
        .target(name: "DesignSystem", dependencies: ["SolverKit"]),
        .target(name: "SolverUI", dependencies: ["SolverKit", "DesignSystem"]),
        .target(name: "OpenRouterKit"),
        .target(name: "BenchKit", dependencies: ["SolverKit", "OpenRouterKit"]),
        .target(name: "BenchUI", dependencies: ["BenchKit", "SolverKit", "OpenRouterKit", "DesignSystem"]),
        .target(name: "ArenaKit", dependencies: ["SolverKit", "OpenRouterKit"]),
        .target(name: "ArenaUI", dependencies: ["ArenaKit", "SolverKit", "OpenRouterKit", "DesignSystem"]),
        .executableTarget(
            name: "Equilibrium",
            dependencies: ["SolverKit", "DesignSystem", "SolverUI", "OpenRouterKit", "BenchKit", "BenchUI", "ArenaKit", "ArenaUI"]
        ),
        .executableTarget(name: "eqbench", dependencies: ["BenchKit", "ArenaKit", "OpenRouterKit", "SolverKit"]),
        .testTarget(name: "SolverKitTests", dependencies: ["SolverKit", "BenchKit", "ArenaKit", "OpenRouterKit"]),
    ],
    swiftLanguageModes: [.v5]
)
