// Entry point: loads data/bench.json (+ arena.json, notes.json) once and renders every section.
// Simple mode needs nothing else; the explorer lazy-loads per-suite decision files in advanced mode.
import { esc, fmt, isAdvanced } from "./util.js";
import { renderCharts, renderRail, whiskerSVG } from "./charts.js";
import { createExplorer } from "./explorer.js";
import { renderInsights, renderConfidence, renderAgreement, findingTakeaways } from "./findings.js";
import { nameBook, renderFormats, renderArena, renderLuna, renderSpotSimple, heroSimple, renderTakeaways, methodSimple, methodAdvanced } from "./sections.js";

const $ = (s) => document.querySelector(s);

// Theme toggle (system default; explicit choice persisted).
$(".theme-toggle").addEventListener("click", () => {
  const cur = document.documentElement.dataset.theme
    ?? (matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark");
  const next = cur === "light" ? "dark" : "light";
  document.documentElement.dataset.theme = next;
  try { localStorage.setItem("eq-theme", next); } catch {}
});

// View mode: simple (default) / advanced. Persisted, and linkable with ?mode=advanced.
function setMode(mode, { persist = true } = {}) {
  document.documentElement.dataset.mode = mode;
  for (const b of document.querySelectorAll(".mode-switch button")) b.setAttribute("aria-pressed", String(b.dataset.mode === mode));
  if (persist) { try { localStorage.setItem("eq-mode", mode); } catch {} }
  const u = new URL(location.href);
  if (mode === "advanced") u.searchParams.set("mode", "advanced"); else u.searchParams.delete("mode");
  history.replaceState(null, "", u.pathname + u.search + u.hash);
  document.dispatchEvent(new CustomEvent("eq:mode", { detail: mode }));
}
for (const b of document.querySelectorAll(".mode-switch button")) {
  b.setAttribute("aria-pressed", String(b.dataset.mode === document.documentElement.dataset.mode));
  b.addEventListener("click", () => setMode(b.dataset.mode));
}

async function getJSON(url, optional = false) {
  try {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`${url} returned HTTP ${res.status}`);
    return await res.json();
  } catch (e) {
    if (optional) return null;
    throw e;
  }
}

async function load() {
  const [bench, arena, notes, insights] = await Promise.all([getJSON("data/bench.json", true), getJSON("data/arena.json", true), getJSON("data/notes.json", true),
    getJSON("data/insights.json", true)]);
  // Older exports: only results.json (the spot suite with decisions).
  const spot = bench?.spot ?? (bench ? null : await getJSON("data/results.json", true));
  if (!bench && !spot) throw new Error("data/bench.json (or data/results.json) not found");
  return { bench, arena, notes, spot, insights };
}

const DM = (p) => p.kind === "decisionModel";

function spotVerdict(data) {
  const { players } = data;
  const dms = players.filter(DM).sort((a, b) => b.overall.score - a.overall.score);
  const base = Object.fromEntries(players.filter((p) => !DM(p)).map((p) => [p.baseline, p]));
  const top = dms[0];
  if (!top) return "No decision-model runs on the spot suite yet — only the reference bots.";
  const cs = base.callingStation?.overall.score, rnd = base.random?.overall.score, gto = base.gto?.overall.score;
  const aboveCS = cs != null ? dms.filter((p) => p.overall.score > cs).length : null;
  const belowRandom = rnd != null ? dms.filter((p) => p.overall.score < rnd).length : 0;
  let v = `The best decision model, <strong>${esc(top.name)}</strong>, keeps <strong>${top.overall.score.toFixed(1)}</strong> of 100 points of available EV`;
  v += gto != null ? `; a bot sampling the solver's own strategy keeps <span class="gold">${gto.toFixed(1)}</span>.` : ".";
  if (aboveCS != null) {
    v += ` ${aboveCS === dms.length ? "Every" : `${aboveCS} of ${dms.length}`} model${aboveCS === 1 && aboveCS !== dms.length ? "" : "s"} beat${aboveCS === 1 && aboveCS !== dms.length ? "s" : ""} a calling station that never folds or raises (<span class="gold">${cs.toFixed(1)}</span>)`;
    v += belowRandom ? `, and ${belowRandom} score${belowRandom === 1 ? "s" : ""} below picking at random.` : ".";
  }
  return v;
}

function hero(ctx) {
  const { spot, bench, arena, book } = ctx;
  const simple = heroSimple(ctx);
  const adv = spot ? spotVerdict(spot) : simple;
  $("#verdict").innerHTML = `<span class="simple">${simple ?? adv ?? "No results exported yet."}</span><span class="adv">${adv ?? simple ?? "No results exported yet."}</span>`;

  // Totals across every part.
  const models = new Set();
  let answers = 0, cost = 0;
  for (const p of spot?.players ?? []) if (DM(p)) { models.add(p.model.replace(/:free$/, "")); answers += p.answered; cost += p.cost?.total ?? 0; }
  for (const s of bench?.suites ?? []) for (const p of s.players) {
    if (p.kind !== "decisionModel") continue;
    models.add(p.model.replace(/:free$/, "")); answers += p.answered; cost += p.cost ?? 0;
  }
  let arenaHands = 0;
  for (const m of arena?.matches ?? []) if (!m.reference) arenaHands += m.hands;
  for (const p of arena?.pairs ?? []) if (p.player.startsWith("dm:")) { models.add(arena.players.find((x) => x.id === p.player)?.model?.replace(/:free$/, "")); cost += p.cost ?? 0; }
  models.delete(undefined);
  const stats = [
    [models.size, "AI models tested", "decision models"],
    [fmt.int(answers), "decisions judged", "decision-model answers scored"],
    arenaHands ? [fmt.int(arenaHands), "arena hands played", "arena hands (decision models)"] : null,
    [fmt.usd(cost), "spent on API calls", "total API cost"],
  ].filter(Boolean);
  $("#hero-stats").innerHTML = stats.map(([v, s, a]) => `<div><dt><span class="simple">${esc(s)}</span><span class="adv">${esc(a)}</span></dt><dd>${esc(v)}</dd></div>`).join("");

  $("#rail-cap").innerHTML = `<span class="simple">Spot test score, 0–100: how much of the best possible value each model keeps per decision. Chips are AI models; gold posts are simple bots for scale.</span>` +
    `<span class="adv">GTO score, 0–100, on the spot suite: the share of the available EV each player keeps per decision. Posts mark the reference bots; chips are decision models.</span>`;

  const dms = spot?.players.filter(DM) ?? [];
  const partial = dms.filter((p) => !p.complete);
  if (partial.length) {
    const n = Math.round(partial.reduce((s, p) => s + p.answered, 0) / partial.length);
    const n_ = $("#notice");
    n_.hidden = false;
    n_.innerHTML = `<strong>Run in progress.</strong> ${partial.length} of ${dms.length} decision models have answered about ${n} of ${spot.suite.decisions} spots so far; hollow dots mark them in the charts and their numbers will move.`;
  }
}

function spotHead(spot) {
  if (!spot) { $("#spot-bench").hidden = true; return; }
  const dms = spot.players.filter(DM).sort((a, b) => b.overall.score - a.overall.score);
  const base = Object.fromEntries(spot.players.filter((p) => !DM(p)).map((p) => [p.baseline, p]));
  $("#sb-eyebrow").textContent = `Part 1 · ${spot.suite.decisions} solved spots`;
  const top = dms[0];
  if (top) {
    $("#sb-headline").innerHTML = `<span class="simple">Best: <strong>${esc(top.name)}</strong>, ${top.overall.score.toFixed(0)} points out of 100` +
      (base.gto ? ` — a perfect-play bot scores ${base.gto.overall.score.toFixed(0)}` : "") + (base.random ? `, random clicking ${base.random.overall.score.toFixed(0)}.` : ".") + `</span>` +
      `<span class="adv">${spotVerdict(spot)}</span>`;
  }
}

// ── Leaderboard ───────────────────────────────────────────
const COLS = [
  { k: "rank", t: "#", cls: "rank l", sort: false },
  { k: "name", t: "Player", cls: "name l", sort: false },
  { k: "score", t: "GTO score ± 95% CI", get: (p) => p.overall.score, desc: true },
  { k: "loss", t: "EV loss<br>% pot", get: (p) => p.overall.lossPot, fmt: (p) => `${fmt.pct(p.overall.lossPot, 2)}` },
  { k: "mixed", t: "Mixed loss<br>% pot", get: (p) => p.overall.mixedPot, fmt: (p) => fmt.pct(p.overall.mixedPot, 2) },
  { k: "tv", t: "TV dist.<br>to GTO", get: (p) => p.overall.tv, fmt: (p) => fmt.num(p.overall.tv, 3) },
  { k: "pbest", t: "P(best)", get: (p) => p.overall.pBest, desc: true, fmt: (p) => fmt.pct(p.overall.pBest, 0) },
  { k: "best", t: "Best<br>action", get: (p) => p.overall.best, desc: true, fmt: (p) => fmt.pct(p.overall.best, 0) },
  { k: "blunder", t: "Blunder", get: (p) => p.overall.blunder, fmt: (p) => fmt.pct(p.overall.blunder, 0) },
  { k: "invalid", t: "Invalid", get: (p) => p.overall.invalid, fmt: (p) => fmt.pct(p.overall.invalid, 0) },
  { k: "cost", t: "$ / 1k<br>decisions", get: (p) => p.cost?.per1k, fmt: (p) => fmt.usd(p.cost?.per1k) },
  { k: "lat", t: "Latency<br>med. / avg", get: (p) => p.latency?.median, fmt: (p) => (p.latency ? `${p.latency.median.toFixed(2)}<span class="dash"> / ${p.latency.mean.toFixed(2)} s</span>` : null) },
];

function leaderboard(data) {
  const players = data.players;
  const table = $("#lb");
  const lo = Math.max(0, Math.floor(Math.min(...players.map((p) => p.overall.score - p.overall.scoreCI)) / 10) * 10);
  const rankOf = new Map(players.filter(DM).sort((a, b) => b.overall.score - a.overall.score).map((p, i) => [p.key, i + 1]));
  let sort = { k: "score", dir: "desc" };

  table.querySelector("thead").innerHTML = `<tr>${COLS.map((c) => {
    if (c.sort === false) return `<th class="${c.cls}" scope="col">${c.t}</th>`;
    return `<th scope="col" data-k="${c.k}" aria-sort="none"><button type="button">${c.t}</button></th>`;
  }).join("")}</tr>`;

  const body = () => {
    const col = COLS.find((c) => c.k === sort.k);
    const rows = players.slice().sort((a, b) => {
      const va = col.get(a), vb = col.get(b);
      if (va == null && vb == null) return b.overall.score - a.overall.score;
      if (va == null) return 1;
      if (vb == null) return -1;
      return sort.dir === "asc" ? va - vb : vb - va;
    });
    table.querySelector("tbody").innerHTML = rows.map((p) => {
      const o = p.overall, dm = DM(p);
      const name = dm
        ? `<a href="${esc(p.url)}" target="_blank" rel="noopener"><span class="n">${esc(p.name)}${p.complete ? "" : `<span class="pill" title="Answered so far">${p.answered}/${p.total}</span>`}</span></a><span class="m" title="${esc(p.model)}${p.servedBy ? ` · served by ${esc(p.servedBy)}` : ""}">${esc(p.model)}</span>`
        : `<span class="n" title="${esc(p.summary ?? "")}">${esc(p.name)}</span><span class="m">reference bot</span>`;
      const cells = COLS.map((c) => {
        if (c.k === "rank") return `<td class="rank l">${dm ? rankOf.get(p.key) : `<span class="sr-only">baseline</span>`}</td>`;
        if (c.k === "name") return `<td class="name l">${name}</td>`;
        if (c.k === "score") {
          return `<td><div class="score-cell">${whiskerSVG(o.score, o.scoreCI, lo, dm ? "var(--s1)" : "var(--gold)", !p.complete)}<b>${o.score.toFixed(1)}</b><small>±${o.scoreCI.toFixed(1)}</small></div></td>`;
        }
        if (c.k === "loss") return `<td>${fmt.pct(o.lossPot, 2)} <span class="dash">±${(o.lossPotCI * 100).toFixed(2)}</span></td>`;
        const v = c.fmt(p);
        return `<td>${v == null || v === "–" ? `<span class="dash">–</span>` : v}</td>`;
      }).join("");
      return `<tr class="${dm ? "dm" : "baseline"}">${cells}</tr>`;
    }).join("");
    for (const th of table.querySelectorAll("th[data-k]")) {
      th.setAttribute("aria-sort", th.dataset.k === sort.k ? (sort.dir === "asc" ? "ascending" : "descending") : "none");
    }
  };
  table.querySelector("thead").addEventListener("click", (e) => {
    const th = e.target.closest("th[data-k]");
    if (!th) return;
    const col = COLS.find((c) => c.k === th.dataset.k);
    sort = sort.k === col.k ? { k: col.k, dir: sort.dir === "asc" ? "desc" : "asc" } : { k: col.k, dir: col.desc ? "desc" : "asc" };
    body();
  });
  body();

  const dms = players.filter(DM).length;
  $("#lb-eyebrow").textContent = `${dms} decision models · ${players.length - dms} reference bots · ${data.suite.decisions} decisions each`;
  const s = data.suite.scoring;
  $("#lb-foot").innerHTML = `GTO score = mean over decisions of 1 − (best EV − chosen EV) / (best EV − worst EV), × 100. EV loss = best EV − chosen EV, in % of the pot. ` +
    `Mixed = Σ p(a) · loss(a) over the model's returned probabilities. TV dist. = ½ Σ |p − GTO| for the hero's exact hand. P(best) = probability placed on best-EV actions. ` +
    `Best action = within ${(s.bestTolerancePot * 100).toFixed(2)}% pot of the top EV. Blunder = loss over ${Math.round(s.blunderThresholdPot * 100)}% pot. Invalid answers count as the worst action. ± is a 95% CI.`;
}

// ── Methodology ───────────────────────────────────────────
function highlightJSON(obj) {
  const s = esc(JSON.stringify(obj, null, 2));
  return s.replace(/(&quot;[^&]*?(?:&(?!quot;)[^&]*?)*&quot;)(\s*:)?|\b(-?\d+(?:\.\d+)?)\b|\b(true|false|null)\b/g, (m, str, colon, num, lit) => {
    if (str) return colon ? `<span class="k">${str}</span>${colon}` : `<span class="s">${str}</span>`;
    if (num) return `<span class="n">${num}</span>`;
    return `<span class="n">${lit}</span>`;
  });
}

function method(data) {
  const s = data.suite, sv = s.solver;
  const scen = s.scenarios.map((x) => `<li><strong>${esc(x.name)}</strong> — ${esc(x.summary)} Pot ${fmt.bb(x.pot)} bb, ${fmt.bb(x.stack)} bb behind. <span class="dash">${x.count} spots</span></li>`).join("");
  const sizes = sv.betSizes.map((b) => `${b.root}: ${esc(b.sizes)}`).join("; ");
  const ex = s.exampleState;
  $("#method-eyebrow").innerHTML = `<span class="simple">How the numbers are made</span><span class="adv">Spot suite ${esc(s.id)} · generated ${fmt.date(s.createdAt)}</span>`;
  $("#method-body").innerHTML = `
    <div>
      <h3>The spot test (Part 1)</h3>
      <p>${s.decisions} decisions were sampled from ${s.solves} solved heads-up subgames (seed ${esc(s.seed)}). Each subgame starts on the ${sv.rootStreets.join(" or ")} of a standard 100 bb preflop scenario:</p>
      <ul>${scen}</ul>
      <p>For each subgame, concrete hands are dealt from both ranges and the tree is walked following the solver's own strategy until a random decision point. The player to act there is the hero; spots where every action is worth about the same (within ${fmt.pct(sv.minEVSpreadPot, 0)} of the pot) are skipped as trivial.</p>
    </div>
    <div>
      <h3>The solver</h3>
      <p>${esc(sv.algorithm)}, written in Rust and run from Equilibrium's macOS app and CLI. Bet trees: ${sizes}; all-in when a bet would commit ${Math.round(sv.allinThreshold * 100)}% of the stack. Solves stop at ${sv.targetExploitabilityPctPot}% pot exploitability or ${sv.maxIterations} iterations; this suite averages <strong>${sv.meanExploitabilityPctPot.toFixed(2)}%</strong> (worst ${sv.maxExploitabilityPctPot.toFixed(2)}%).</p>
      <h3 style="margin-top:22px">Approximations</h3>
      <ul>${s.approximations.map((a) => `<li>${esc(a)}</li>`).join("")}</ul>
    </div>
    <div>
      <h3>Asking a decision model</h3>
      <p>OpenRouter's System One <a href="https://openrouter.ai/models?output_modalities=decisions" target="_blank" rel="noopener">decision models</a> don't write text. They read a structured <code>state</code> and answer typed questions with a probability for every option. Each spot is sent once to <code>POST /api/alpha/decisions</code> with one <code>choice</code> question whose options are the legal actions.</p>
      <p>The state spells out what a player at the table would know — cards (also written out in words), positions, the betting line street by street with sizes in % of pot, stacks, pot odds, stack-to-pot ratio, and the hero's made hand and draws. The villain's cards are never sent. The model's pick is scored as its action; its probabilities are scored as a mixed strategy. Decision-model output is free, so cost is input tokens × input price (~${ex?.approxInputTokens ?? "1,000"} tokens a spot).</p>
    </div>
    <div>
      <h3>What the metrics mean</h3>
      <dl class="metrics">
        <dt>GTO score</dt><dd>Share of the EV gap kept: 100 for the best action, 0 for the worst, per decision, averaged. Random lands near ${data.players.find((p) => p.baseline === "random")?.overall.score.toFixed(0) ?? "55"}.</dd>
        <dt>EV loss</dt><dd>Best action's EV minus the chosen action's EV, in % of the pot, for the hero's exact hand against a GTO opponent.</dd>
        <dt>Mixed EV loss</dt><dd>The same, if the model played its returned distribution instead of its top pick.</dd>
        <dt>TV distance</dt><dd>How far the model's distribution is from the solver's mix for that hand: 0 = identical, 1 = no overlap.</dd>
        <dt>P(best)</dt><dd>Probability the model put on the best-EV action(s). A calibration check.</dd>
        <dt>Blunder</dt><dd>A pick that loses more than ${Math.round(s.scoring.blunderThresholdPot * 100)}% of the pot.</dd>
      </dl>
    </div>
    <div class="full">
      <h3>Caveats</h3>
      <ul>
        <li>${s.decisions} spots is a small sample; the confidence intervals are wide and overlapping models should be read as ties.</li>
        <li>Scores are against equilibrium play, not against real opponents' leaks. A model that exploits humans well could still score poorly here.</li>
        <li>OpenRouter may route a model to different providers; the provider that actually served it is listed where known.</li>
        <li>Mixed strategies matter in poker: GTO often splits a hand between actions of equal EV, so "best action" and TV distance can disagree.</li>
        <li>Results as of ${fmt.date(data.generatedAt)}. Models are updated; re-run to compare versions.</li>
      </ul>
    </div>
    ${ex ? `<div class="full"><details class="state"><summary>Example request for ${esc(ex.decision)} — the exact state and question a model receives</summary><pre class="code"><code>${highlightJSON(ex.body)}</code></pre></details></div>` : ""}
  `;

}

// ── Routing & lazy explorer ───────────────────────────────
function setupExplorer(ctx) {
  const { bench, spot } = ctx;
  const sources = [];
  if (spot) sources.push({ key: "spots", label: `Spot suite · ${spot.suite.decisions} spots`, file: "data/results.json" });
  for (const s of bench?.suites ?? []) if (s.file) sources.push({ key: s.key, label: `${s.format.short} ${s.mode === "preflop" ? "preflop" : "hands"}${s.split ? ` · ${s.split}` : ""} · ${s.decisions} decisions`, file: `data/${s.file}` });
  const sel = $("#ex-suite");
  if (!sources.length) { $("#explorer").hidden = true; return; }
  sel.innerHTML = sources.map((s) => `<option value="${esc(s.key)}">${esc(s.label)}</option>`).join("");
  sel.closest("label").hidden = sources.length < 2;
  const cache = {};
  let ex = null;
  const ensure = () => (ex ??= createExplorer($("#ex-root")));
  async function show(key, id) {
    const src = sources.find((s) => s.key === key) ?? sources[0];
    sel.value = src.key;
    $("#ex-list").setAttribute("aria-busy", "true");
    try {
      cache[src.key] ??= await (await fetch(src.file)).json();
    } catch (e) {
      $("#ex-spot").innerHTML = `<p class="empty-note">Could not load ${esc(src.file)} (${esc(e.message)}).</p>`;
      return;
    } finally { $("#ex-list").removeAttribute("aria-busy"); }
    const e = ensure();
    if (e.key !== src.key || !e.data) e.load(cache[src.key], src.key);
    e.open(id ?? defaultSpot(cache[src.key]));
  }
  sel.addEventListener("change", () => show(sel.value));
  const fromHash = () => {
    const m = /^#(?:([\w-]+)\/)?(d\d{2,4})?$/i.exec(location.hash);
    if (!m || (!m[2] && !m[1]) || !sources.some((s) => s.key === (m[1] ?? "spots"))) return false;
    if (!isAdvanced()) setMode("advanced", { persist: false });
    show(m[1] ?? "spots", m[2]?.toLowerCase());
    requestAnimationFrame(() => $("#explorer").scrollIntoView({ behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" }));
    return true;
  };
  window.addEventListener("hashchange", fromHash);
  if (fromHash()) return;
  const io = new IntersectionObserver((entries) => {
    if (entries.some((e) => e.isIntersecting) && !ex) { io.disconnect(); show(sources[0].key); }
  }, { rootMargin: "600px 0px" });
  io.observe($("#explorer"));
}

/** Open on a decision where the models split — the interesting ones. */
function defaultSpot(data) {
  const dmIdx = data.players.map((p, i) => (p.kind !== "baseline" ? i : -1)).filter((i) => i >= 0);
  let best = data.decisions[0]?.id, bestScore = -1;
  for (const d of data.decisions) {
    const picks = dmIdx.map((i) => d.answers[i]).filter((a) => a && a[0] >= 0).map((a) => a[0]);
    if (picks.length < 3) continue;
    const counts = {};
    for (const c of picks) counts[c] = (counts[c] ?? 0) + 1;
    const split = 1 - Math.max(...Object.values(counts)) / picks.length;
    if (split > bestScore) { bestScore = split; best = d.id; }
  }
  return best;
}

function footer(ctx) {
  const { bench, arena, spot } = ctx;
  const when = bench?.generatedAt ?? spot?.generatedAt;
  const files = [bench && `<a href="data/bench.json">bench.json</a>`, spot && `<a href="data/results.json">results.json</a>`, arena && `<a href="data/arena.json">arena.json</a>`].filter(Boolean).join(" · ");
  $("#footer-meta").innerHTML = `Data exported ${fmt.date(when)} · ${files} · <a href="https://openrouter.ai/models?output_modalities=decisions" target="_blank" rel="noopener">OpenRouter decision models</a>`;
}

try {
  const ctx = await load();
  ctx.book = nameBook(ctx.bench, ctx.spot);
  hero(ctx);
  renderInsights(ctx.insights, ctx.bench);
  ctx.extraTakeaways = findingTakeaways(ctx.bench);
  renderTakeaways(ctx);
  renderConfidence(ctx.bench);
  if (ctx.spot) {
    renderRail(ctx.spot, $("#rail-plot"));
    spotHead(ctx.spot);
    renderSpotSimple(ctx.spot);
    leaderboard(ctx.spot);
    renderCharts(ctx.spot, $("#charts"));
    method(ctx.spot);
  } else {
    $("#rail").hidden = true;
    spotHead(null);
  }
  renderAgreement(ctx.bench);
  renderFormats(ctx.bench, ctx.notes);
  renderArena(ctx.arena, ctx.book, ctx.notes);
  renderLuna(ctx.bench, ctx.notes);
  methodSimple(ctx);
  methodAdvanced(ctx);
  footer(ctx);
  setupExplorer(ctx);
  // Sections render after load: honour a section hash (#confidence, #agreement…) once content exists.
  if (location.hash && !location.hash.startsWith("#insight-") && /^#[a-z][\w-]*$/i.test(location.hash)) document.getElementById(location.hash.slice(1))?.scrollIntoView();
} catch (err) {
  console.error(err);
  $("#verdict").innerHTML = `Could not load the results (${esc(err.message)}). Serve this folder over HTTP — for example <code>python3 -m http.server</code> inside <code>web/</code> — and check that <code>data/bench.json</code> exists (<code>eqbench bench export --all</code> writes it).`;
}
