# Equilibrium benchmark — results site

A static, dependency-free website for the Equilibrium poker benchmark: OpenRouter
System One decision models vs. a GTO solver (solved spots, full hands per format, preflop)
and vs. bots (arena), plus the prompt-variant experiments.

```
web/
  index.html            homepage: "AI Poker Championship" highlight reel (broadcast.css, broadcast.js)
  full.html             full results: insights, confidence, spots, agreement, formats, arena, Luna, explorer, method
  styles.css            all styles (dark/light via prefers-color-scheme + a toggle; simple/advanced view modes)
  js/app.js             entry: loads data/bench.json + arena.json + notes.json, renders every section, view mode
  js/sections.js        formats, arena and Luna sections, simple-mode headlines/takeaways, methodology
  js/charts.js          hand-made SVG charts (no chart library)
  js/explorer.js        decision explorer for any exported suite (lazy-loads its decision file)
  js/util.js            formatting, cards, action colours, tooltips, mini Markdown for notes
  data/bench.json       manifest: spot leaderboard, every published suite, per-format bb/100, dev/test experiments
  data/results.json     the spot suite with every decision (explorer)
  data/suites/<key>.json  per-decision data for each published suite that has model runs (explorer, lazy)
  data/arena.json       arena matches, per-opponent pooled results, ratings (`eqbench arena export`)
  data/notes.json       optional hand-written conclusions per section (simple + advanced text)
  favicon.svg
```

No build step. The only network dependency is Google Fonts (the page falls back to
system fonts offline).

## View modes

**Simple** (default) is plain language: a headline per section, a few big charts, no tables.
**Advanced** shows every metric, CI, paired difference, breakdown table, the explorer, the
exact request JSON and the full methodology. The header toggle is remembered in
`localStorage`; `?mode=advanced` links straight to it. Both read the same data; simple mode
never downloads per-decision files.

## Re-export the data

From the repo root, whenever runs, suites or matches change (no API calls, safe to repeat):

```sh
make bench-cli                              # or: cd app && swift build -c release --product eqbench
eqbench bench export --all --no-catalog     # results.json + bench.json + suites/*.json
eqbench arena export                        # arena.json
```

`bench export --all` options: `--out-dir web/data`, `--spots <suite>` (spot suite; default: the
spots suite with the most decision-model runs), `--focus <model>` (experiments model; default
`openai/gpt-6-luna-decisions`), `--pretty`, `--no-catalog` (skip the OpenRouter model catalog;
names/prices then come from the built-in list and billed cost). Published suites: hands suites
with ≥ 50 decisions, preflop suites with ≥ 100; dev/test splits borrow the parent's bot baselines.
The per-format numbers equal `eqbench bench formats --published`; paired differences equal
`eqbench bench compare --suite <split> --ref "<focus> [v2]"`. `arena export` takes `--min-hands 100`
and `--out`. Exports contain no API keys and no raw model responses.

`data/notes.json` is optional prose per section (`formats`, `arena`, `luna`), each with a
`simple` and an `advanced` text (blank line = paragraph, `**bold**`, `*italic*`, `` `code` ``,
`[link](url)`). `luna.best` names a run label, display name or variant id to highlight as the
configuration confirmed on the test split; otherwise the export's own `confirmed` flag (better on
dev, test difference CI excluding 0) is used.

## Preview locally

The page fetches `data/*.json`, so open it over HTTP rather than `file://`:

```sh
cd web && python3 -m http.server 8000     # http://localhost:8000
```

## Publish

The `web/` folder is the whole site. Any static host works.

- **GitHub Pages**: branch deploys only serve `/` or `/docs`, so either copy `web/`
  to `docs/` and pick *Settings → Pages → Deploy from a branch → /docs*, or set the
  source to *GitHub Actions* and use a workflow that runs
  `actions/upload-pages-artifact` with `path: web` followed by `actions/deploy-pages`.
- **Netlify**: drag the `web` folder onto <https://app.netlify.com/drop>. Or connect
  the repo with *Base directory* `web`, no build command, *Publish directory* `web`.
- **Cloudflare Pages**: *Create → Pages → Upload assets* and drop `web/`, or
  `npx wrangler pages deploy web --project-name equilibrium-bench`.
- **Vercel**: `cd web && npx vercel --prod` (framework preset: Other, no build).

Deep links use the hash (`/#d042` for the spot suite, `/#cash-hands-dev/d042` for another suite), so no server rewrites are needed.
