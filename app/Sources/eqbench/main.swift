import ArenaKit
import BenchKit
import Foundation
import LLMKit

let usage = """
eqbench — benchmark LLM poker decisions against GTO.

USAGE:
  eqbench models [filter]          List OpenRouter models
  eqbench bench <subcommand> ...   GTO EV-loss benchmark (run `eqbench bench help`)
  eqbench arena <subcommand> ...   Heads-up matches (run `eqbench arena help`)

The OpenRouter key is read from OPENROUTER_API_KEY or the app's keychain entry.
"""

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "models":
        let client = try OpenRouterClient.fromStoredKey()
        let filter = args.dropFirst().first?.lowercased()
        for m in try await client.models() where filter == nil || m.id.lowercased().contains(filter!) {
            let p = m.promptPricePerM.map { String(format: "$%.2f", $0) } ?? "?"
            let c = m.completionPricePerM.map { String(format: "$%.2f", $0) } ?? "?"
            print("\(m.id.padding(toLength: 48, withPad: " ", startingAt: 0)) in \(p)/M  out \(c)/M")
        }
    case "bench":
        try await BenchCLI.run(Array(args.dropFirst()))
    case "arena":
        try await ArenaCLI.run(Array(args.dropFirst()))
    default:
        print(usage)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
