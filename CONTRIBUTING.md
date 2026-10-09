# Contributing

Thanks for poking at Equilibrium! Bug reports, solver checks, new prompt variants and new
scenarios are all welcome. Please open an issue first for anything large.

## Dev setup

Requirements: macOS 26+, Xcode 26+ (Swift 6 toolchain), Rust stable (`rustup`).

```sh
make core        # cargo build --release → core/target/release/libgto_core.a (the Swift package links it)
make test        # cd core && cargo test --release; cd app && swift test
make run         # assemble build/Equilibrium.app and open it
make bench-cli   # app/.build/release/eqbench
```

The Swift package (`app/Package.swift`) links the Rust static library from
`core/target/release`, so **build the core first**. A Swift build will fail to link if you skip it.

You only need an OpenRouter key (`cp .env.example .env`) to call decision models. Everything else
runs offline: solving, suite generation, bot baselines, scoring, `bench synth`, exports and arena
matches between bots. **Never commit `.env`**, which is gitignored.

Benchmark state lives outside the repo, in `~/Library/Application Support/Equilibrium/{suites,runs,arena}`.

## Tests

- Rust: `cd core && cargo test --release`. This covers the evaluator, ranges, closed-form toy games
  and isomorphic-vs-full trees.
- Swift: `cd app && swift test`. This covers solver wrappers, suite generation, variants, scoring,
  the arena engine and exports. No test calls the network.

## Adding a decision-model variant (prompt or state)

Variants live in `app/Sources/BenchKit/DecisionVariants.swift`. Larger ones get their own file,
for example `NutVariant.swift`.

1. Write a `DecisionVariant(id:summary:build:interpret:)`:
   - `build` returns the `state` JSON and the `questions` for one `Decision`. Start from
     `DecisionStateBuilder.state(d)` (the `v2` state) and add facts, or see `minimalState` for a
     stripped-down one.
   - `interpret` maps the API answer to one probability vector over the legal actions. Use
     `singleChoice` for one `choice` question, or `averagedChoices` and `noulPerAction` for multi-question variants.
2. Append it to `DecisionVariants.all`. `eqbench bench run --variant <id>`, `bench variants`, the
   app and the exports pick it up, and the run label becomes `model [id]`.
3. **Never leak solver data** into the state: no GTO strategy, EVs, solver equities or villain
   cards. Only use what a player at the table could know or compute (see `EquityTools`).
4. Add a test in `app/Tests/SolverKitTests/BenchKitTests.swift`, at least checking that the request
   builds and that the answer keys map back to the right actions.
5. Evaluate it honestly: run it on a **dev** split, and only claim an improvement once it is
   confirmed on the held-out **test** split:

   ```sh
   eqbench bench state --suite <id> --decision d001 --variant <id>       # inspect the exact request (free)
   eqbench bench run --suite <id>-dev  --models openai/gpt-6-luna-decisions --variant v2,<id>
   eqbench bench compare --suite <id>-dev  --ref "openai/gpt-6-luna-decisions [v2]"
   eqbench bench run --suite <id>-test --models openai/gpt-6-luna-decisions --variant v2,<id>
   eqbench bench compare --suite <id>-test --ref "openai/gpt-6-luna-decisions [v2]"
   ```

## Adding a scenario or format

- Scenarios (preflop ranges, pot, stack) are in `app/Sources/SolverKit/Presets.swift`
  (`Scenarios.cash` / `Scenarios.tournament`, ranges in `RangeLibrary` / `TournamentRanges`, in
  PioSolver syntax with optional `:weight`).
- Their sampling weights for full-hand suites are in `SuiteGenerator.scenarioWeights`
  (`app/Sources/BenchKit/HandsGenerator.swift`). Bet-size trees are chosen per scenario SPR.
- Game formats (`cash`, `mtt40`, `mtt20`, `spin`) and how suites are grouped into website columns are
  in `SolverKit` (`GameFormat`) and `BenchKit/FormatPool.swift`. Preflop suites come from
  `BenchKit/PreflopGenerator.swift` and `core/src/preflop.rs`.
- Generate a suite to try it: `eqbench bench generate --mode hands --format <f> --scenarios <id> --hands 20`.

## Regenerating suites and website data

```sh
eqbench bench generate --mode hands --format cash --hands 120 --seed 1   # CPU only, ~30 s per flop solve
eqbench bench baselines --suite <id>
eqbench bench export --all --no-catalog    # → web/data/{results,bench}.json + web/data/suites/*.json
eqbench arena export                       # → web/data/arena.json
cd web && python3 -m http.server 8000
```

Exports never contain API keys or raw model responses. Prose conclusions live in
`web/data/notes.json`, which is edited by hand (see `web/README.md`). If you change numbers, update
the notes and the README's *Key findings* so they stay in sync.

## Style

- Rust: `cargo fmt`. Swift: follow the surrounding code (Swift 6 toolchain, language mode 5).
- Keep the website dependency-free (no frameworks, no build step).
- Keep claims modest: report confidence intervals and sample sizes, and keep negative results.
