# Equilibrium benchmark — results site

A static, dependency-free website for the Equilibrium poker benchmark: OpenRouter
System One decision models vs. a GTO solver on solved heads-up no-limit hold'em spots.

```
web/
  index.html          single page: hero, leaderboard, charts, spot explorer, methodology
  styles.css          all styles (dark/light via prefers-color-scheme + a toggle)
  js/app.js           entry: loads data/results.json once, renders every section
  js/charts.js        hand-made SVG charts (no chart library)
  js/explorer.js      spot explorer (lazy: renders when scrolled near, or on #d042 links)
  js/util.js          formatting, cards, action colours, tooltips
  data/results.json   the data, written by `eqbench bench export`
  favicon.svg
```

No build step. The only network dependency is Google Fonts (the page falls back to
system fonts offline).

## Re-export the data

From the repo root, after running a benchmark:

```sh
make bench-cli                      # or: cd app && swift build -c release --product eqbench
eqbench bench export                # newest suite → web/data/results.json
eqbench bench export --suite 20261009-160813-rt-n200-s2026 --out web/data/results.json
```

Options: `--pretty` (indented JSON), `--no-catalog` (skip the live OpenRouter catalog;
model names and input prices then come from the built-in list and billed cost). The
export contains no API keys and no raw model responses.

## Preview locally

The page fetches `data/results.json`, so open it over HTTP rather than `file://`:

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

Deep links to a spot use the hash (`/#d042`), so no server rewrites are needed.
