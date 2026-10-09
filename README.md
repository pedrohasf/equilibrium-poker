<img src="assets/AppIcon.svg" width="96" height="96" alt="">

# Equilibrium

A native macOS GTO poker lab:

- **Solver** — a heads-up postflop no-limit hold'em solver in the spirit of
  [TexasSolver](https://github.com/bupticybee/TexasSolver): Discounted CFR over
  vectorised ranges, written in Rust, with a SwiftUI workbench (range editor,
  board picker, live convergence chart, GTO-Wizard-style strategy matrix,
  per-combo EV/equity inspector).
- **Model Benchmarks** — measures how much EV OpenRouter
  [decision models](https://openrouter.ai/models?output_modalities=decisions)
  (TypeSafe Jev, Liquid d1, Cloudflare Clef, GPT-6 Luna Decisions, …) lose
  versus the solved equilibrium, decision by decision. They return a probability
  for every action, so they are also scored as mixed strategies (mixed EV loss,
  distance to the GTO mix, P(best action)).
- **Arena** — full heads-up matches between decision models and bots
  (decision models play argmax or sample their returned distribution), in duplicate format,
  with bb/100, all-in-EV, player stats and hand-history replays.

## Build & run

Requirements: macOS 26+, Xcode 26+ (Swift 6), Rust (stable).

```sh
make run          # builds core + app, assembles build/Equilibrium.app, opens it
make test         # Rust + Swift tests
make bench-cli    # builds the `eqbench` command-line tool
```

Add your OpenRouter key in **Settings (⌘,)** — it is stored in the macOS
keychain — or export `OPENROUTER_API_KEY` for the CLI.

## Layout

```
core/                 Rust solver (static lib + `solve` CLI)
  src/solver.rs       DCFR, best response / exploitability, queries
  src/tree.rs         game tree builder (bet sizes, raise caps, all-in threshold)
  src/eval.rs         7-card hand evaluator
  src/range.rs        PioSolver-style range parser
  src/ffi.rs          C ABI (JSON in/out) → include/gto_core.h
app/                  Swift package
  SolverKit           Swift wrapper around the core, cards/ranges/presets
  DesignSystem        theme + shared components
  SolverUI            solver workbench
  OpenRouterKit       OpenRouter decisions client, keychain
  BenchKit / BenchUI  GTO EV-loss benchmark
  ArenaKit / ArenaUI  heads-up match engine & table
  eqbench             CLI for benchmarks and arena matches
examples/             sample solver configs (`core/target/release/solve examples/…`)
```

## Solver notes

- **Algorithm**: Discounted CFR (α = 1.5, β = 0.5, γ = 3) with alternating
  updates and the average strategy restarted at powers of four. Exploitability
  is measured exactly with a best-response pass and reported in % of the pot.
- **Suit isomorphism**: when suits are interchangeable (e.g. the two suits
  missing from a two-tone flop) the mirrored turn/river subtrees are solved once
  and their values permuted — 25–55% less memory and time on such boards.
- **Validated** against closed-form toy games (polarised river: bluff ⅓ of the
  betting range, call 50%) and by comparing isomorphic vs. full trees.
- Typical speeds on an M4 Pro: river spots instant, turn spots ≈0.3 s, a
  single-size flop tree (≈2.8 GB) to 0.3% pot in about a minute.

## Quick start: benchmark decision models

```sh
export OPENROUTER_API_KEY=sk-or-...
eqbench bench decision-models                         # live catalog + prices
eqbench bench generate --decisions 60 --seed 1        # solve spots → suite
eqbench bench run --suite <id> --models typesafe/jev-1.13,liquid/d1,cloudflare/clef
eqbench bench report
eqbench bench state --suite <id> --decision d001      # exact request sent
eqbench arena match --a dm:typesafe/jev-1.13 --b bot:tag --deals 100
```

Decision models are called through `POST /api/alpha/decisions` (fallback
`/api/v1/systemone`) with a structured JSON `state` and one `choice` question
whose options are the legal actions, plus derived facts (made hand, draws, pot
odds, SPR) as the API guidance recommends. Chat/text models are intentionally
not supported.

## Benchmark methodology

Three complementary measurements, all against equilibrium play:

1. **Full-hand suites** (`generate --mode hands --format cash|mtt40|mtt20|spin`) — the
   most realistic postflop test. A flop is solved from the scenario's preflop
   ranges, concrete hands are dealt, and each hand is played to the end following
   GTO; **every decision of both players on flop, turn and river** is recorded,
   so turn/river ranges are correctly narrowed. No triviality filter. Reported as
   **postflop bb/100 lost vs GTO** (Σ EV loss per hand ÷ 2 seats, 95% CI over
   hands) plus per-decision metrics.
2. **Preflop suites** (`--mode preflop`) — heads-up preflop (blind vs blind, Spin
   HU) from the preflop solver: exact push/fold Nash at ≤12bb, a full
   open/limp/3-bet/4-bet tree deeper, with flops valued by an equity-realisation
   model. Reported as preflop bb/100.
3. **Arena** — complete hands (preflop → river) in duplicate format against
   bots that model real opponent types (TAG regular, calling station, maniac).

**Formats** are distinguished by stack depth, antes and preflop ranges: cash
100bb, MTT 40bb and 20bb (1bb big-blind ante), Spin & Go (25bb 3-handed / 15bb
HU). Tournament results are chip EV — ICM is not modelled.

**Metrics.** EV loss = EV(best action) − EV(chosen action) for the exact hand
against a GTO opponent. Decision models return a probability for every action,
so they are also scored as mixed strategies (mixed EV loss, total-variation
distance to the GTO mix, P(best)). Experiments with state/question **variants**
(`--variant v2|minimal|eq|eqrange|coach|multi|noul`), ensembles and
temperature (`bench synth`) are tuned on a dev split and confirmed on a held-out
test split (`bench split`, `bench compare` with paired CIs).
