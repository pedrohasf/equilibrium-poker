// Parts 2–4 (formats, arena, Luna experiments), simple-mode summaries and the takeaways.
// Every renderer degrades to a short "no data yet" message when its slice of the data is missing.
import { esc, fmt, ttRows, bindTips, mount, md, signed, isAdvanced } from "./util.js";
import { rowsChart, dot } from "./charts.js";

const $ = (s) => document.querySelector(s);

// ── Shared vocabulary ─────────────────────────────────────
/** Plain-language names for request variants (simple view). Unknown variants fall back to their summary. */
export const VARIANT_PLAIN = {
  v2: "Standard prompt",
  minimal: "Bare facts only",
  eq: "Adds win-chance numbers",
  eqrange: "Adds win chance vs. a narrowed range",
  coach: "Poker-coach wording",
  multi: "Asks three ways, averages",
  noul: "Yes/no question per move",
  nuts: "Adds “what beats me” hand ranking",
  shortstack: "Adds short-stack advice",
};
const VARIANT_SHORT = { v2: "Standard", minimal: "Bare facts", eq: "Win %", eqrange: "Win % vs range", coach: "Coach wording", multi: "Asked 3 ways", noul: "Yes/no per move", nuts: "Nut ranking", shortstack: "Short-stack tips" };
/** Variants confirmed on held-out data; shown next to the standard prompt in the format charts. */
const IMPROVED = ["nuts", "shortstack"];
const IMPROVED_BY_PHASE = { postflop: ["nuts"], preflop: ["shortstack"] };
const isShown = (r, phase) => r.kind === "decisionModel" && (r.variant === "v2" || (IMPROVED_BY_PHASE[phase] ?? []).includes(r.variant));
const playerName = (r, adv) => {
  if (adv) return r.name;
  const base = r.modelName ?? r.name;
  return r.variant && IMPROVED.includes(r.variant) ? `${base} · improved` : base;
};
const PHASE_PLAIN = { preflop: "before the flop", postflop: "after the flop" };
const OPP_PLAIN = {
  "bot:tag": ["Against a solid regular", "TAG bot: tight and aggressive"],
  "bot:station": ["Against a calling station", "never folds, never raises"],
  "bot:maniac": ["Against a maniac", "bets and raises at every chance"],
  "bot:random": ["Against a random player", "picks moves at random"],
};
const BASE_PLAIN = { gto: "Perfect-play bot", callingStation: "Calling station", random: "Random play", bestEV: "Best-move oracle" };

/** Model id → friendly name, from every player object in the bench export. */
export function nameBook(bench, spot) {
  const book = {};
  for (const p of spot?.players ?? []) if (p.kind === "decisionModel") book[p.model] ??= p.name.replace(/ \[[^\]]+\]$/, "");
  for (const s of bench?.suites ?? []) for (const p of s.players) if (p.modelName) book[p.model] ??= p.modelName;
  for (const r of bench?.formats?.rows ?? []) if (r.modelName) book[r.model] ??= r.modelName;
  return book;
}
function arenaName(id, book, arena) {
  const p = arena?.players?.find((x) => x.id === id);
  if (!p) return id;
  if (p.kind === "bot") return arena.bots?.find((b) => b.id === id)?.title ?? p.name;
  return (book[p.model] ?? p.name) + (p.mode === "mixed" ? " · sampled" : "");
}
const bb = (x, d = 0) => (x == null ? "–" : fmt.num(x, d));
const ciText = (m, c, d = 0) => (m == null ? "–" : `${signed(m, d)} ± ${c == null ? "?" : c.toFixed(d)}`);
const lossText = (m, c, d = 0) => (m == null ? "–" : `${m.toFixed(d)} ± ${c == null ? "?" : c.toFixed(d)}`);

function empty(el, text) { if (el) el.innerHTML = `<p class="empty-note">${esc(text)}</p>`; }

/** Whisker + dot for one estimate on a rowsChart row; values outside the axis are clamped with an arrow. */
function ciMark(x, cy, m, c, color, { hollow = false, dy = 0, label = null } = {}) {
  const [lo, hi] = x.domain;
  const y = cy + dy;
  const clamp = (v) => Math.max(lo, Math.min(hi, v));
  let s = "";
  if (c != null && c > 0) {
    const a = x(clamp(m - c)), b = x(clamp(m + c));
    s += `<line x1="${a}" x2="${b}" y1="${y}" y2="${y}" stroke="${color}" stroke-width="2" stroke-linecap="round" opacity=".55"/>`;
    if (m - c >= lo) s += `<line x1="${a}" x2="${a}" y1="${y - 4}" y2="${y + 4}" stroke="${color}" stroke-width="2" opacity=".55"/>`;
    if (m + c <= hi) s += `<line x1="${b}" x2="${b}" y1="${y - 4}" y2="${y + 4}" stroke="${color}" stroke-width="2" opacity=".55"/>`;
  }
  const cx = x(clamp(m));
  if (m > hi || m < lo) {
    const dir = m > hi ? 1 : -1;
    s += `<path d="M${cx - dir * 7} ${y - 5} L${cx} ${y} L${cx - dir * 7} ${y + 5}" fill="none" stroke="${color}" stroke-width="2"/>`;
  } else s += dot(cx, y, color, 5, hollow);
  if (label) s += `<text class="val" x="${x(clamp(c != null ? m + c : m)) + 8}" y="${y + 4}">${esc(label)}</text>`;
  return s;
}

function legendHTML(items) {
  return items.map(([t, c, hollow]) => `<span><i style="${hollow ? `border:2px solid var(--${c});background:transparent` : `background:var(--${c})`}"></i>${esc(t)}</span>`).join("");
}

function renderNotes(el, note) {
  if (!el) return;
  if (!note || (!note.simple && !note.advanced)) { el.innerHTML = ""; el.hidden = true; return; }
  el.hidden = false;
  const simple = note.simple ?? note.advanced, adv = note.advanced ?? note.simple;
  el.innerHTML = `<div class="simple">${md(simple)}</div><div class="adv">${md(adv)}</div>`;
}

// ── Part 2: formats ───────────────────────────────────────
export function formatsSummary(bench) {
  const f = bench?.formats;
  if (!f?.columns?.length) return null;
  const rows = f.rows ?? [];
  const models = rows.filter((r) => r.kind === "decisionModel");
  const withData = f.columns.filter((c) => models.some((r) => r.cells[c.key]));
  const waiting = f.columns.filter((c) => !withData.includes(c));
  const best = withData.map((c) => {
    const v2 = models.filter((r) => r.variant === "v2" && r.cells[c.key]);
    const pool = v2.length ? v2 : models.filter((r) => r.cells[c.key]);
    const top = pool.slice().sort((a, b) => a.cells[c.key].bb - b.cells[c.key].bb)[0];
    const st = rows.find((r) => r.baseline === "callingStation")?.cells[c.key];
    return { col: c, row: top, cell: top.cells[c.key], station: st };
  });
  return { columns: f.columns, withData, waiting, best, rows };
}

/** One plain sentence: where models lose most / least (best model per format column). */
export function formatsSentence(S) {
  const where = (b) => `${b.col.format.short}`;
  const range = (bs) => {
    const v = bs.map((b) => Math.round(b.cell.bb)).sort((a, b) => a - b);
    return v[0] === v[v.length - 1] ? `${v[0]}` : `${v[0]}–${v[v.length - 1]}`;
  };
  const post = S.best.filter((b) => b.col.phase === "postflop").sort((a, b) => b.cell.bb - a.cell.bb);
  const pre = S.best.filter((b) => b.col.phase === "preflop");
  const parts = [];
  if (post.length) parts.push(`After the flop the best model gives away about ${range(post)} big blinds per 100 hands` +
    (post.length > 1 ? ` — most in ${where(post[0])}, least in ${where(post[post.length - 1])}` : ` (${where(post[0])})`));
  if (pre.length) parts.push(`${post.length ? "before" : "Before"} the flop only about ${range(pre)}`);
  return parts.join("; ") + ".";
}

export function renderFormats(bench, notes) {
  renderNotes($("#fm-notes"), notes?.formats);
  const S = formatsSummary(bench);
  const facets = $("#fm-facets");
  if (!S) {
    $("#fm-headline").textContent = "";
    empty(facets, "No full-hand or preflop suites have been exported yet. Run `eqbench bench export --all` after generating them.");
    $("#fm-table").closest(".adv").hidden = true;
    return;
  }
  const head = $("#fm-headline");
  if (S.best.length) {
    const b = S.best.filter((x) => x.col.phase === "postflop").sort((x, y) => x.cell.bb - y.cell.bb)[0] ?? S.best[0];
    head.innerHTML = `<span class="simple">${esc(formatsSentence(S))}` +
      (S.waiting.length ? ` Not yet measured: ${esc(S.waiting.map((c) => `${c.format.short} ${PHASE_PLAIN[c.phase]}`).join(", "))}.` : "") + `</span>` +
      `<span class="adv">Lowest postflop bb/100 lost (default variant): <strong>${esc(b.row.label)}</strong> ${lossText(b.cell.bb, b.cell.ci, 1)} in ${esc(b.col.title)} (n = ${b.cell.n} hands)` +
      (S.waiting.length ? `. No model runs yet: ${esc(S.waiting.map((c) => c.title).join(", "))}.` : ".") + `</span>`;
  } else {
    head.innerHTML = `Suites are generated (${esc(S.columns.map((c) => c.title).join(", "))}) but no model has played them yet — only the reference bots.`;
  }

  // Controls (advanced): variants, argmax vs mixed.
  const state = { variants: false, mixed: false };
  const ctrl = $("#fm-controls");
  ctrl.innerHTML = segHTML("fm-var", "Players", [["v2", "Default + improved"], ["all", "All variants & derived"]]) +
    segHTML("fm-mix", "Scoring", [["pick", "Pick (argmax)"], ["mixed", "Distribution (mixed)"]]);
  bindSeg(ctrl, (name, v) => {
    if (name === "fm-var") state.variants = v === "all";
    if (name === "fm-mix") state.mixed = v === "mixed";
    redrawAll();
  });

  const tips = {};
  const draws = [];
  const cellOf = (r, c) => {
    const x = r.cells[c.key];
    if (!x) return null;
    return state.mixed && isAdvanced() ? (x.mixed != null ? { m: x.mixed, c: x.mixedCI, n: x.n } : null) : { m: x.bb, c: x.ci, n: x.n };
  };
  const cols = S.withData.length ? S.withData : [];
  facets.innerHTML = cols.map((c) => `<figure class="chart facet" data-col="${esc(c.key)}"><figcaption><h3><span class="simple">${esc(c.format.short)} · ${esc(PHASE_PLAIN[c.phase])}</span><span class="adv">${esc(c.title)}</span></h3>` +
    `<p class="simple">${esc(c.format.summary.replace(/ Chip EV.*$/, ""))}</p><p class="adv fm-sub"></p></figcaption><div class="plot"></div></figure>`).join("") +
    (S.waiting.length ? `<div class="facet waiting"><h3>Waiting for model runs</h3><ul>${S.waiting.map((c) => `<li><strong>${esc(c.format.short)}</strong> ${esc(PHASE_PLAIN[c.phase])} <span class="dash">· ${c.hands} hands generated</span></li>`).join("")}</ul><p class="footnote">These suites exist; their numbers appear here after a re-export once models have played them.</p></div>` : "");

  for (const c of cols) {
    const fig = facets.querySelector(`[data-col="${CSS.escape(c.key)}"]`);
    const plot = fig.querySelector(".plot");
    const draw = (el) => {
      const adv = isAdvanced();
      const players = S.rows.filter((r) => r.kind !== "baseline" && r.cells[c.key] && (adv && state.variants ? true : isShown(r, c.phase)));
      const vals = players.map((r) => ({ r, v: cellOf(r, c) })).filter((x) => x.v).sort((a, b) => a.v.m - b.v.m);
      if (!vals.length) { el.innerHTML = `<p class="empty-note">No ${state.mixed ? "distribution " : ""}data for this view.</p>`; return; }
      const base = Object.fromEntries(S.rows.filter((r) => r.kind === "baseline").map((r) => [r.baseline, cellOf(r, c)]).filter(([, v]) => v));
      const hiModel = Math.max(...vals.map((x) => x.v.m + (x.v.c ?? 0)));
      const refs = [], off = [];
      for (const k of ["gto", "callingStation", "random"]) {
        if (!base[k]) continue;
        const label = adv ? (k === "gto" ? "GTO" : k === "callingStation" ? "Calling stn" : "Random") : BASE_PLAIN[k];
        if (base[k].m <= hiModel * (k === "callingStation" ? 3 : 1.35)) refs.push({ v: base[k].m, label });
        else off.push(`${label} ${Math.round(base[k].m)}`);
      }
      const hi = Math.max(hiModel, ...refs.map((r) => r.v)) * 1.06 || 10;
      fig.querySelector(".fm-sub").textContent = `bb/100 lost vs GTO (${state.mixed ? "mixed" : "argmax"}) ± 95% CI · dot = mean${off.length ? ` · off scale: ${off.join(", ")}` : ""}`;
      const simpleSub = fig.querySelector("p.simple");
      if (simpleSub && off.length && !simpleSub.dataset.off) { simpleSub.dataset.off = 1; simpleSub.textContent += ` Off the chart: ${off.join(", ")}.`; }
      for (const { r, v } of vals) {
        const x = r.cells[c.key];
        tips[`${c.key}:${r.label}`] = `<b>${esc(adv ? r.label : playerName(r, false))}</b>${ttRows([
          !adv && r.variant && IMPROVED.includes(r.variant) && ["What changed", VARIANT_PLAIN[r.variant]],
          [adv ? "bb/100 lost (argmax)" : "Big blinds lost per 100 hands", lossText(x.bb, x.ci, 1)],
          adv && x.mixed != null && ["bb/100 lost (mixed)", lossText(x.mixed, x.mixedCI, 1)],
          ["Hands", String(x.n)],
          adv && ["Suites", x.suites.join(", ")],
          r.derived?.hybrid && ["Note", "hybrid (heuristic-assisted)"],
        ])}`;
      }
      rowsChart(el, {
        aria: `${c.title}: big blinds lost per 100 hands versus perfect play. ${vals.map(({ r, v }) => `${r.name} ${Math.round(v.m)}`).join(", ")}.`,
        rows: vals.map(({ r, v }) => ({ key: `${c.key}:${r.label}`, label: playerName(r, adv), short: playerName(r, adv).replace(/^(GPT-6 |TypeSafe |Liquid |Inception |Cloudflare |Upstage |Perplexity )/, "") })),
        x: { lo: 0, hi, fmt: (t) => String(t) },
        refs, labelW: 210, right: 70, rowH: 32,
        marks: (row, x, cy) => {
          const v = vals.find((q) => `${c.key}:${q.r.label}` === row.key).v;
          return ciMark(x, cy, v.m, v.c, "var(--s1)", { label: Math.round(v.m) });
        },
      });
    };
    draws.push(mount(plot, draw));
    bindTips(fig, (k) => tips[k]);
  }
  function redrawAll() { for (const d of draws) d?.(); }
  document.addEventListener("eq:mode", redrawAll);

  // Advanced table.
  const tcols = S.columns;
  const order = (r) => (r.kind === "decisionModel" ? 0 : r.kind === "derived" ? 1 : 2);
  const rows = S.rows.slice().sort((a, b) => order(a) - order(b) || a.label.localeCompare(b.label));
  $("#fm-table thead").innerHTML = `<tr><th class="l" scope="col">Player</th>${tcols.map((c) => `<th scope="col">${esc(c.title)}<br><span class="dash">${c.hands} hands</span></th>`).join("")}</tr>`;
  $("#fm-table tbody").innerHTML = rows.map((r) => `<tr class="${r.kind === "baseline" ? "baseline" : ""}"><td class="name l"><span class="n">${esc(r.name)}${r.derived?.hybrid ? ` <span class="pill">hybrid</span>` : ""}</span><span class="m">${esc(r.kind === "derived" ? r.derived?.method ?? "derived" : r.label)}</span></td>` +
    tcols.map((c) => {
      const x = r.cells[c.key];
      return x ? `<td>${x.bb.toFixed(1)} <span class="dash">±${x.ci.toFixed(1)} [${x.n}]</span>${x.mixed != null ? `<br><span class="dash">mixed ${x.mixed.toFixed(1)}</span>` : ""}</td>` : `<td><span class="dash">–</span></td>`;
    }).join("") + `</tr>`).join("");
  $("#fm-foot").innerHTML = `bb/100 lost vs GTO, argmax ± 95% CI [hands]; mixed = playing the returned distribution. Pooled over every published suite of the format (same numbers as <code>eqbench bench formats --published</code>). Preflop and postflop are separate samples; a full-hand figure is roughly their sum. Chip EV — ICM is not modelled.`;

  const suites = bench.suites ?? [];
  $("#fm-suites thead").innerHTML = `<tr><th class="l" scope="col">Suite</th><th scope="col">Format</th><th scope="col">Decisions</th><th scope="col">Hands</th><th scope="col">Players</th><th scope="col">Mean expl.<br>% pot</th><th class="l" scope="col">Explorer</th></tr>`;
  $("#fm-suites tbody").innerHTML = suites.map((s) => `<tr><td class="name l"><span class="n">${esc(s.key)}</span><span class="m">${esc(s.id)}</span></td><td>${esc(s.format.short)} ${esc(s.mode)}${s.split ? ` · ${esc(s.split)}` : ""}</td>` +
    `<td>${s.decisions}</td><td>${s.hands}</td><td>${s.players.filter((p) => p.kind !== "baseline").length} + ${s.players.filter((p) => p.kind === "baseline").length} bots</td><td>${s.meanExplPctPot.toFixed(2)}</td>` +
    `<td class="l">${s.file ? `<a href="#${esc(s.key)}/">open</a>` : `<span class="dash">bots only</span>`}</td></tr>`).join("");
}

// ── Part 3: arena ─────────────────────────────────────────
export function arenaSummary(arena, book) {
  if (!arena?.pairs?.length) return null;
  const dms = [...new Set(arena.pairs.filter((p) => p.player.startsWith("dm:") && p.opponent.startsWith("bot:")).map((p) => p.player))];
  if (!dms.length) return null;
  const oppOrder = ["bot:tag", "bot:station", "bot:maniac", "bot:random"];
  const opps = oppOrder.filter((o) => arena.pairs.some((p) => p.opponent === o && dms.includes(p.player)));
  const get = (pl, op) => arena.pairs.find((p) => p.player === pl && p.opponent === op);
  const byTag = dms.map((d) => ({ d, p: get(d, "bot:tag") })).filter((x) => x.p).sort((a, b) => b.p.bb100 - a.p.bb100);
  return { dms, opps, get, byTag, name: (id) => arenaName(id, book, arena) };
}

export function renderArena(arena, book, notes) {
  renderNotes($("#ar-notes"), notes?.arena);
  const A = arenaSummary(arena, book);
  const facets = $("#ar-facets");
  if (!A) {
    $("#ar-headline").textContent = "";
    empty(facets, "No arena matches with decision models yet. Run `eqbench arena match …` and then `eqbench arena export`.");
    $("#ar-table").closest(".adv").hidden = true;
    return;
  }
  $("#ar-min").textContent = arena.minHands;
  // Headline.
  const t = A.byTag[0];
  const sta = A.dms.map((d) => A.get(d, "bot:station")).filter(Boolean).sort((a, b) => a.bb100 - b.bb100);
  let h = "";
  if (t) {
    const p = t.p, even = p.ci95 != null && Math.abs(p.bb100) <= p.ci95;
    const verb = even ? "roughly breaks even" : p.bb100 > 0 ? `wins ${Math.round(p.bb100)} big blinds per 100 hands` : `loses ${Math.round(-p.bb100)} big blinds per 100 hands`;
    const beaten = A.byTag.filter((x) => x.p.ci95 != null && x.p.bb100 < -x.p.ci95).length;
    h += `<span class="simple">Against a solid regular, the best model — <strong>${esc(A.name(t.d))}</strong> — ${verb}` +
      (A.byTag.length > 1 ? `; ${beaten ? `${beaten} of ${A.byTag.length} models clearly lose${beaten === 1 ? "s" : ""} to it` : "no model clearly loses to it"}.` : ".");
    if (sta.length) h += ` Against a bot that never folds, ${sta.every((x) => x.bb100 > 0) ? "every model wins" : "results vary"}: from ${signed(sta[0].bb100)} to ${signed(sta[sta.length - 1].bb100)} per 100 hands.`;
    h += `</span><span class="adv">Best vs TAG: <strong>${esc(t.d)}</strong> ${ciText(p.bb100, p.ci95, 1)} bb/100 over ${p.hands} hands. ` +
      (sta.length ? `Vs calling station: ${ciText(sta[0].bb100, sta[0].ci95)} (${esc(A.name(sta[0].player))}) to ${ciText(sta[sta.length - 1].bb100, sta[sta.length - 1].ci95)} (${esc(A.name(sta[sta.length - 1].player))}).` : "") + `</span>`;
  }
  $("#ar-headline").innerHTML = h;

  const tips = {};
  const rowsOrder = (A.byTag.length ? A.byTag.map((x) => x.d) : A.dms).concat(A.dms.filter((d) => !A.byTag.some((x) => x.d === d)));
  facets.innerHTML = A.opps.map((o) => `<figure class="chart facet" data-opp="${esc(o)}"><figcaption><h3>${esc((OPP_PLAIN[o] ?? [A.name(o)])[0])}</h3><p><span class="simple">${esc((OPP_PLAIN[o] ?? ["", ""])[1])}. Big blinds won per 100 hands; the bar shows how sure we are.</span><span class="adv">${esc(o)} · bb/100 ± 95% CI over duplicate pairs</span></p></figcaption><div class="plot"></div></figure>`).join("");
  for (const o of A.opps) {
    const fig = facets.querySelector(`[data-opp="${CSS.escape(o)}"]`);
    const ref = o !== "bot:tag" ? A.get("bot:tag", o) : null;
    const rows = rowsOrder.map((d) => ({ d, p: A.get(d, o) })).filter((x) => x.p);
    for (const { d, p } of rows) {
      tips[`${o}|${d}`] = `<b>${esc(A.name(d))}</b> <span class="dash">vs ${esc(A.name(o))}</span>${ttRows([
        [isAdvanced() ? "bb/100" : "Big blinds per 100 hands", ciText(p.bb100, p.ci95, 1)],
        isAdvanced() && ["All-in EV bb/100", ciText(p.evBB100, p.evCI95, 1)],
        ["Hands", String(p.hands)],
        ["Plays a hand (VPIP)", fmt.pct(p.vpip, 0)],
        ["Raises before the flop (PFR)", fmt.pct(p.pfr, 0)],
        isAdvanced() && ["Cost", fmt.usd(p.cost)],
      ])}`;
    }
    const redraw = mount(fig.querySelector(".plot"), (el) => {
      const ext = rows.flatMap(({ p }) => [p.bb100 - (p.ci95 ?? 0), p.bb100 + (p.ci95 ?? 0)]).concat(ref ? [ref.bb100] : [], [0]);
      let lo = Math.min(...ext), hi = Math.max(...ext);
      const pad = (hi - lo) * 0.06 || 10;
      lo -= pad; hi += pad;
      rowsChart(el, {
        aria: `${(OPP_PLAIN[o] ?? [o])[0]}: big blinds won per 100 hands. ${rows.map(({ d, p }) => `${A.name(d)} ${signed(p.bb100)}`).join(", ")}.`,
        rows: rows.map(({ d }) => ({ key: `${o}|${d}`, label: A.name(d), short: A.name(d).replace(/^(GPT-6 |TypeSafe |Liquid |Inception |Cloudflare )/, "") })),
        x: { lo, hi, fmt: (v) => signed(v) },
        zero: 0,
        refs: ref ? [{ v: ref.bb100, label: isAdvanced() ? `TAG bot ${signed(ref.bb100)}` : `Regular bot ${signed(ref.bb100)}` }] : [],
        labelW: 200, right: 64, rowH: 32,
        marks: (row, x, cy) => {
          const p = rows.find((q) => `${o}|${q.d}` === row.key).p;
          return ciMark(x, cy, p.bb100, p.ci95, p.bb100 >= 0 ? "var(--s1)" : "var(--s2)", { label: signed(p.bb100) });
        },
      });
    });
    document.addEventListener("eq:mode", () => redraw?.());
    bindTips(fig, (k) => tips[k]);
  }
  $("#ar-legend").innerHTML = legendHTML([["Won (above 0)", "s1"], ["Lost (below 0)", "s2"]]) + `<span class="dash">Gold line: the regular bot's own result, for scale.</span>`;

  // Advanced tables.
  const cols = A.opps;
  $("#ar-table thead").innerHTML = `<tr><th class="l" scope="col">Decision model</th>${cols.map((o) => `<th scope="col">vs ${esc(A.name(o))}<br>bb/100 ± CI</th><th scope="col">EV<br>bb/100</th>`).join("")}` +
    `<th scope="col">VPIP</th><th scope="col">PFR</th><th scope="col">3-bet</th><th scope="col">AF</th><th scope="col">WTSD</th><th scope="col">Hands</th><th scope="col">Invalid</th><th scope="col">Cost</th></tr>`;
  const pooled = (d, f) => {
    const ps = cols.map((o) => A.get(d, o)).filter((p) => p && p[f] != null);
    const n = ps.reduce((s, p) => s + p.hands, 0);
    return n ? ps.reduce((s, p) => s + p[f] * p.hands, 0) / n : null;
  };
  const afText = (d) => cols.map((o) => A.get(d, o)?.af).map((v) => (v == null ? "–" : v > 20 ? ">20" : v.toFixed(1))).join(" / ");
  $("#ar-table tbody").innerHTML = rowsOrder.map((d) => {
    const ps = cols.map((o) => A.get(d, o));
    const hands = ps.reduce((s, p) => s + (p?.hands ?? 0), 0);
    const cost = ps.reduce((s, p) => s + (p?.cost ?? 0), 0);
    const inv = ps.reduce((s, p) => s + (p?.invalid ?? 0), 0), dec = ps.reduce((s, p) => s + (p?.decisions ?? 0), 0);
    return `<tr><td class="name l"><span class="n">${esc(A.name(d))}</span><span class="m">${esc(d)}</span></td>` +
      ps.map((p) => (p ? `<td>${signed(p.bb100, 1)} <span class="dash">±${p.ci95?.toFixed(1) ?? "?"} [${p.hands}]</span></td><td>${signed(p.evBB100, 1)}</td>` : `<td><span class="dash">–</span></td><td><span class="dash">–</span></td>`)).join("") +
      `<td>${fmt.pct(pooled(d, "vpip"), 0)}</td><td>${fmt.pct(pooled(d, "pfr"), 0)}</td><td>${fmt.pct(pooled(d, "threeBet"), 0)}</td><td>${afText(d)}</td><td>${fmt.pct(pooled(d, "wtsd"), 0)}</td>` +
      `<td>${hands}</td><td>${dec ? fmt.pct(inv / dec, 1) : "–"}</td><td>${fmt.usd(cost)}</td></tr>`;
  }).join("");
  $("#ar-foot").innerHTML = `bb/100 ± 95% CI over duplicate pairs [hands]; EV = all-in-EV adjusted. VPIP / PFR / 3-bet / WTSD pooled over both opponents (hand-weighted); AF = postflop (bets + raises) / calls, per opponent (${cols.map((o) => esc(A.name(o))).join(" / ")}; “>20” = almost never calls). Cost = OpenRouter input tokens billed. Same numbers as <code>eqbench arena show</code> / <code>arena leaderboard</code>.`;

  const refs = arena.pairs.filter((p) => p.reference && p.player < p.opponent);
  $("#ar-ref thead").innerHTML = `<tr><th class="l" scope="col">Bot</th><th class="l" scope="col">vs</th><th scope="col">bb/100 ± CI</th><th scope="col">EV bb/100</th><th scope="col">Hands</th><th scope="col">VPIP</th><th scope="col">PFR</th></tr>`;
  $("#ar-ref tbody").innerHTML = refs.length ? refs.map((p) => `<tr class="baseline"><td class="name l"><span class="n">${esc(A.name(p.player))}</span></td><td class="name l">${esc(A.name(p.opponent))}</td>` +
    `<td>${ciText(p.bb100, p.ci95, 1)}</td><td>${signed(p.evBB100, 1)}</td><td>${p.hands}</td><td>${fmt.pct(p.vpip, 0)}</td><td>${fmt.pct(p.pfr, 0)}</td></tr>`).join("")
    : `<tr><td colspan="7" class="l">No bot-vs-bot reference matches.</td></tr>`;
}

// ── Part 4: Luna experiments ──────────────────────────────
function variantPlain(r, bench) {
  if (r.kind === "decisionModel" && r.variant) return VARIANT_PLAIN[r.variant] ?? bench.variants?.find((v) => v.id === r.variant)?.summary ?? r.variant;
  return r.name;
}

export function lunaSummary(bench, notes, i = 0) {
  const exps = bench?.experiments ?? [];
  if (!exps.length) return null;
  const e = exps[Math.min(i, exps.length - 1)];
  const focus = e.rows.filter((r) => r.focus && r.kind === "decisionModel" && r.variant !== "v2");
  const pure = e.rows.filter((r) => r.focus && !(r.derived?.hybrid) && !(r.kind === "decisionModel" && r.variant === "v2"));
  const bestDev = pure.filter((r) => r.dev?.diff?.bb).sort((a, b) => a.dev.diff.bb.mean - b.dev.diff.bb.mean)[0];
  const confirmed = e.rows.filter((r) => r.confirmed);
  const flagged = notes?.luna?.best ? e.rows.find((r) => [r.label, r.name, r.variant].includes(notes.luna.best)) : null;
  return { e, focus, bestDev, confirmed, flagged };
}

let luTips = {};
export function renderLuna(bench, notes, idx = 0) {
  renderNotes($("#lu-notes"), notes?.luna);
  const L = lunaSummary(bench, notes, idx);
  const fig = $("#lu-chart");
  // Fresh plot element per render (old observers keep drawing into the detached one).
  const oldPlot = fig.querySelector(".plot"), freshPlot = document.createElement("div");
  freshPlot.className = "plot";
  oldPlot.replaceWith(freshPlot);
  const exps = bench?.experiments ?? [];
  const pick = $("#lu-pick");
  if (exps.length > 1) {
    pick.hidden = false;
    pick.innerHTML = `<label class="pick">Experiment <select>${exps.map((x, i) => `<option value="${i}"${i === idx ? " selected" : ""}>${esc(x.format.short)} ${esc(x.mode)} · ${esc(x.focusName)}</option>`).join("")}</select></label>`;
    pick.querySelector("select").addEventListener("change", (ev) => renderLuna(bench, notes, +ev.target.value), { once: true });
  } else pick.hidden = true;
  if (!L) {
    $("#lu-headline").textContent = "";
    empty(fig.querySelector(".plot"), "No dev/test experiments exported yet. Split a hands suite (`eqbench bench split`), run variants on the dev half, then re-export.");
    $("#lu-table").closest(".adv").hidden = true;
    return;
  }
  const { e } = L;
  $("#lu-title").textContent = `Pushing ${e.focusName}`;
  $("#lu-foot").dataset.root = e.root;
  const plain = (r) => variantPlain(r, bench);
  const star = L.flagged ?? L.confirmed[0];
  const devHands = e.splits.find((s) => s.split === "dev")?.hands, testHands = e.splits.find((s) => s.split === "test")?.hands;
  let h = "";
  if (star) {
    const t = star.test?.diff?.bb;
    h = `<span class="simple"><strong>${esc(plain(star))}</strong> made ${esc(e.focusName)} better on fresh hands: about ${Math.round(Math.abs(t?.mean ?? 0))} fewer big blinds lost per 100 hands than the standard prompt.</span>` +
      `<span class="adv">${L.flagged ? "Flagged" : "Confirmed on test"}: <strong>${esc(star.label)}</strong> — test Δ ${t ? ciText(t.mean, t.ci, 1) : "–"} bb/100 vs v2 (n = ${t?.n ?? 0} hands).</span>`;
  } else if (L.bestDev) {
    const d = L.bestDev.dev.diff.bb, t = L.bestDev.test?.diff?.bb;
    const testPhrase = !t ? "it has not been checked on fresh hands yet"
      : t.mean < 0 && t.sig ? `on fresh hands it is better too (${signed(t.mean)} per 100 hands)`
      : t.mean < 0 ? `on fresh hands it still looks a bit better (${signed(t.mean)} per 100 hands), but within the noise so far`
      : `on fresh hands the gain disappears (${signed(t.mean)} per 100 hands)`;
    h = `<span class="simple">Best idea on practice hands: <strong>${esc(plain(L.bestDev))}</strong> (${signed(d.mean)} big blinds per 100 hands vs. the standard prompt) — ${testPhrase}.</span>` +
      `<span class="adv">Best pure configuration on dev: <strong>${esc(L.bestDev.label)}</strong> Δ ${ciText(d.mean, d.ci, 1)} bb/100 (n = ${d.n}); test Δ ${t ? `${ciText(t.mean, t.ci, 1)} (n = ${t.n})` : "not run yet"}. No configuration is confirmed on test (CI excluding 0) yet.</span>`;
  }
  $("#lu-headline").innerHTML = h;

  const state = { derived: false, others: false, mixed: false };
  const ctrl = $("#lu-controls");
  ctrl.innerHTML = segHTML("lu-set", "Players", [["variants", "Prompt variants"], ["derived", "+ derived"], ["all", "+ other models & bots"]]) +
    segHTML("lu-mix", "Scoring", [["pick", "Pick (argmax)"], ["mixed", "Distribution (mixed)"]]);
  $("#lu-legend").innerHTML = legendHTML([[`Practice hands (dev, ${devHands ?? "?"} hands)`, "s1"], [`Fresh hands (test, ${testHands ?? "?"} hands)`, "s2"]]);

  const tips = (luTips = {});
  const plot = freshPlot;
  const draw = (el) => {
    if (!el.isConnected) return;
    const adv = isAdvanced();
    const mix = adv && state.mixed;
    const key = mix ? "mixed" : "bb";
    $("#lu-chart-title").innerHTML = adv ? `Δ bb/100 lost vs ${esc(e.focusName)} [v2] (${mix ? "mixed" : "argmax"}), paired, 95% CI`
      : `How each idea changed the big blinds lost per 100 hands`;
    $("#lu-chart-sub").innerHTML = adv ? "Negative = loses less than v2. Paired over hands both answered; hollow = run still in progress."
      : "Compared with the standard prompt (the line at 0). <strong>Left is better.</strong> The bar shows how sure we are; a bar that crosses 0 means the difference could be luck.";
    const groups = [["Prompt variants", e.rows.filter((r) => r.focus && r.kind === "decisionModel" && r.variant !== "v2")]];
    if (adv && (state.derived || state.others)) groups.push(["Derived from stored answers (no extra API calls)", e.rows.filter((r) => r.focus && r.kind === "derived")]);
    if (adv && state.others) groups.push(["Other models and bots", e.rows.filter((r) => !r.focus)]);
    const rows = [];
    for (const [title, rs] of groups) {
      const keep = rs.filter((r) => r.dev?.diff?.[key] || r.test?.diff?.[key]).sort((a, b) => (a.dev?.diff?.[key]?.mean ?? 1e9) - (b.dev?.diff?.[key]?.mean ?? 1e9));
      if (!keep.length) continue;
      if (groups.length > 1) rows.push({ header: true, label: title, key: title });
      for (const r of keep) {
        const strong = r === star || r.confirmed;
        rows.push({ key: r.label, r, strong, label: (adv ? r.name : plain(r)) + (strong ? " ✓" : ""), short: (adv ? r.name.replace(/^gpt-6-luna-decisions /i, "").replace(/^GPT-6 Luna Decisions /, "") : (r.kind === "decisionModel" && VARIANT_SHORT[r.variant]) || plain(r)) + (strong ? " ✓" : "") });
        tips[r.label] = `<b>${esc(adv ? r.label : plain(r))}</b>${r.derived ? `<div class="tt-row"><span>${esc(r.derived.description)}</span></div>` : ""}${ttRows([
          ...["dev", "test"].flatMap((sp) => {
            const c = r[sp];
            if (!c) return [[sp === "dev" ? "Practice (dev)" : "Fresh (test)", "not run"]];
            const d = c.diff?.[key];
            return [[sp === "dev" ? "Practice (dev): lost /100" : "Fresh (test): lost /100", lossText(mix ? c.mixed : c.bb, mix ? c.mixedCI : c.ci)],
              [sp === "dev" ? "  change vs standard" : "  change vs standard", d ? ciText(d.mean, d.ci, 1) : "–"],
              adv && !c.complete && ["  answered", `${c.answered}/${c.total}`]];
          }),
        ])}`;
      }
    }
    if (!rows.length) { el.innerHTML = `<p class="empty-note">No paired results for this view yet.</p>`; return; }
    const ext = rows.filter((r) => !r.header).flatMap(({ r }) => ["dev", "test"].flatMap((sp) => { const d = r[sp]?.diff?.[key]; return d ? [d.mean - d.ci, d.mean + d.ci] : []; }));
    const m = Math.min(260, Math.max(20, ...ext.map(Math.abs))) * 1.05;
    rowsChart(el, {
      aria: `Change in big blinds lost per 100 hands versus the standard prompt, on practice and fresh hands, for ${rows.filter((r) => !r.header).length} configurations.`,
      rows, x: { lo: -m, hi: m, fmt: (v) => (v === 0 ? (adv ? "0 = v2" : "standard") : signed(v)) }, zero: 0, labelW: adv ? 300 : 250, right: 18, rowH: 36,
      marks: (row, x, cy) => {
        let s = "";
        const dv = row.r.dev?.diff?.[key], ts = row.r.test?.diff?.[key];
        if (dv) s += ciMark(x, cy, dv.mean, dv.ci, "var(--s1)", { dy: ts ? -6 : 0, hollow: !row.r.dev.complete });
        if (ts) s += ciMark(x, cy, ts.mean, ts.ci, "var(--s2)", { dy: dv ? 6 : 0, hollow: !row.r.test.complete });
        return s;
      },
    });
  };
  const redraw = mount(plot, draw);
  if (!fig.dataset.tips) { fig.dataset.tips = 1; bindTips(fig, (k) => luTips[k]); }
  bindSeg(ctrl, (name, v) => {
    if (name === "lu-set") { state.derived = v !== "variants"; state.others = v === "all"; }
    if (name === "lu-mix") state.mixed = v === "mixed";
    redraw?.();
  });
  document.addEventListener("eq:mode", () => redraw?.());

  // Advanced table.
  const cell = (c) => (c ? `${c.bb != null ? c.bb.toFixed(1) : "–"} <span class="dash">±${c.ci?.toFixed(1) ?? "?"} [${c.hands}]</span>${c.complete ? "" : `<span class="pill" title="Answered so far">${c.answered}/${c.total}</span>`}` : `<span class="dash">–</span>`);
  const dcell = (c, k = "bb") => {
    const d = c?.diff?.[k];
    if (c?.isReference) return `<span class="dash">(ref)</span>`;
    return d ? `<span class="${d.sig ? (d.mean < 0 ? "good-t" : "bad-t") : ""}">${ciText(d.mean, d.ci, 1)}${d.sig ? "*" : ""}</span>` : `<span class="dash">–</span>`;
  };
  const kindOf = (r) => (r.kind === "decisionModel" ? (r.focus ? "variant" : "model") : r.kind === "derived" ? (r.derived?.hybrid ? "hybrid" : r.derived?.method ?? "derived") : "bot");
  const grp = (r) => (r.focus && r.kind === "decisionModel" ? 0 : r.focus ? 1 : r.kind === "baseline" ? 3 : 2);
  const rows = e.rows.slice().sort((a, b) => grp(a) - grp(b) || (a.dev?.bb ?? 1e9) - (b.dev?.bb ?? 1e9));
  $("#lu-table thead").innerHTML = `<tr><th class="l" scope="col">Player</th><th scope="col">Kind</th><th scope="col">Dev bb/100<br>± CI [hands]</th><th scope="col">Dev Δ vs v2</th><th scope="col">Test bb/100<br>± CI [hands]</th><th scope="col">Test Δ vs v2</th><th scope="col">Dev Δ<br>mixed</th><th scope="col">Test Δ<br>mixed</th><th scope="col">Dev GTO<br>score</th><th scope="col">Cost</th></tr>`;
  $("#lu-table tbody").innerHTML = rows.map((r) => `<tr class="${r.kind === "baseline" ? "baseline" : ""}${r === star || r.confirmed ? " star" : ""}"><td class="name l"><span class="n">${esc(r.name)}${r.confirmed ? ` <span class="pill">confirmed</span>` : ""}</span><span class="m" title="${esc(r.derived?.description ?? bench.variants?.find((v) => v.id === r.variant)?.summary ?? "")}">${esc(r.derived?.description ?? bench.variants?.find((v) => v.id === r.variant)?.summary ?? r.label)}</span></td>` +
    `<td>${esc(kindOf(r))}</td><td>${cell(r.dev)}</td><td>${dcell(r.dev)}</td><td>${cell(r.test)}</td><td>${dcell(r.test)}</td><td>${dcell(r.dev, "mixed")}</td><td>${dcell(r.test, "mixed")}</td>` +
    `<td>${r.dev ? r.dev.score.toFixed(1) : "–"}</td><td>${fmt.usd((r.dev?.cost ?? 0) + (r.test?.cost ?? 0) || null)}</td></tr>`).join("");
  $("#lu-foot").innerHTML = `Suite ${esc(e.root)} split by hand into dev (${devHands ?? "?"} hands) and test (${testHands ?? "?"} hands). Δ = paired difference vs <code>${esc(e.splits[0]?.reference ?? "v2")}</code> over the complete hands both answered (as <code>eqbench bench compare --ref</code>); * = 95% CI excludes 0; green = significantly better. Baselines are borrowed from the parent suite. “Confirmed” = better on dev and significantly better on test. Derived players reuse stored answers (no API cost); <em>hybrid</em> ones add a heuristic and are not pure model results.`;
}

// ── Small segmented control helper ─────────────────────────
function segHTML(name, label, opts) {
  return `<div class="seg" role="radiogroup" aria-label="${esc(label)}" data-seg="${esc(name)}">${opts.map(([v, t], i) => `<button type="button" role="radio" aria-checked="${i === 0}" data-v="${esc(v)}">${esc(t)}</button>`).join("")}</div>`;
}
function bindSeg(root, onChange) {
  for (const seg of root.querySelectorAll("[data-seg]")) {
    seg.addEventListener("click", (e) => {
      const b = e.target.closest("button");
      if (!b) return;
      for (const x of seg.querySelectorAll("button")) x.setAttribute("aria-checked", String(x === b));
      onChange(seg.dataset.seg, b.dataset.v);
    });
    seg.addEventListener("keydown", (e) => {
      if (!["ArrowLeft", "ArrowRight"].includes(e.key)) return;
      const bs = [...seg.querySelectorAll("button")];
      const i = bs.findIndex((x) => x.getAttribute("aria-checked") === "true");
      const n = bs[(i + (e.key === "ArrowRight" ? 1 : bs.length - 1)) % bs.length];
      n.focus(); n.click(); e.preventDefault();
    });
  }
}

// ── Simple spot chart (Part 1) ────────────────────────────
export function renderSpotSimple(spot) {
  const fig = $("#ch-score-simple");
  if (!spot?.players?.length) { empty(fig.querySelector(".plot"), "No spot benchmark exported yet."); return; }
  const dms = spot.players.filter((p) => p.kind === "decisionModel").sort((a, b) => b.overall.score - a.overall.score);
  const base = Object.fromEntries(spot.players.filter((p) => p.kind === "baseline").map((p) => [p.baseline, p]));
  const refs = ["random", "callingStation", "gto"].filter((k) => base[k]).map((k) => ({ v: base[k].overall.score, label: BASE_PLAIN[k] }));
  const lo = Math.max(0, Math.floor(Math.min(...dms.map((p) => p.overall.score - p.overall.scoreCI), ...refs.map((r) => r.v)) / 10) * 10);
  const tips = {};
  for (const p of dms) tips[p.key] = `<b>${esc(p.name)}</b>${ttRows([["Points kept", `${p.overall.score.toFixed(1)} of 100`], ["Picked the best move", fmt.pct(p.overall.best, 0)], ["Big mistakes", fmt.pct(p.overall.blunder, 0)]])}`;
  mount(fig.querySelector(".plot"), (el) => rowsChart(el, {
    aria: `Points kept out of 100 for ${dms.length} decision models. Best: ${dms[0]?.name} at ${dms[0]?.overall.score.toFixed(1)}.`,
    rows: dms.map((p) => ({ key: p.key, label: p.name, short: p.name.replace(/^(GPT-6 |TypeSafe |Liquid |Inception |Cloudflare |Upstage |Perplexity |Together )/, "") })),
    x: { lo, hi: 100, fmt: (v) => v }, refs, labelW: 230, right: 54, rowH: 32,
    marks: (row, x, cy) => { const o = dms.find((p) => p.key === row.key).overall; return ciMark(x, cy, o.score, o.scoreCI, "var(--s1)", { label: o.score.toFixed(0) }); },
  }));
  bindTips(fig, (k) => tips[k]);
}

// ── Takeaways & hero (simple) ──────────────────────────────
export function heroSimple(ctx) {
  if (ctx.notes?.hero) return md(ctx.notes.hero).replace(/<\/?p[^>]*>/g, "");
  const { spot, bench, arena, book } = ctx;
  const A = arenaSummary(arena, book), S = formatsSummary(bench);
  const top = A?.byTag[0];
  const spotTop = spot?.players?.filter((p) => p.kind === "decisionModel").sort((a, b) => b.overall.score - a.overall.score)[0];
  const model = top ? arena.players.find((p) => p.id === top.d)?.model : spotTop?.model;
  if (!model) return null;
  const name = book[model] ?? model;
  const parts = [];
  if (top) {
    const p = top.p, even = p.ci95 != null && Math.abs(p.bb100) <= p.ci95;
    parts.push(even ? "breaks even against a solid regular bot" : p.bb100 > 0 ? `beats a solid regular bot by ${Math.round(p.bb100)} big blinds per 100 hands` : `loses ${Math.round(-p.bb100)} big blinds per 100 hands to a solid regular bot`);
  }
  const fm = S?.rows.find((r) => r.model === model && r.kind === "decisionModel" && r.variant === "v2");
  const cols = (S?.withData ?? []).filter((c) => fm?.cells[c.key]);
  const col = cols.find((c) => c.format.id === "cash" && c.phase === "postflop") ?? cols.find((c) => c.phase === "postflop") ?? cols[0];
  if (fm && col) parts.push(`but gives away about ${Math.round(fm.cells[col.key].bb)} big blinds per 100 hands to perfect play (${col.format.short}, ${PHASE_PLAIN[col.phase]})`);
  else if (spotTop) parts.push(`and keeps ${spotTop.overall.score.toFixed(0)} of 100 points against perfect play`);
  return `Best model: <strong>${esc(name)}</strong> — ${parts.join(", ")}.`;
}

export function renderTakeaways(ctx) {
  const { spot, bench, arena, book } = ctx;
  const items = [...(ctx.extraTakeaways ?? [])];
  const dms = spot?.players?.filter((p) => p.kind === "decisionModel") ?? [];
  const cs = spot?.players?.find((p) => p.baseline === "callingStation")?.overall.score;
  if (dms.length) {
    const top = dms.slice().sort((a, b) => b.overall.score - a.overall.score)[0];
    const above = cs != null ? dms.filter((p) => p.overall.score > cs).length : null;
    items.push(["Single decisions", `The best model, ${top.name}, kept ${top.overall.score.toFixed(0)} of 100 points on ${spot.suite.decisions} solved spots.` +
      (above != null ? ` ${above === dms.length ? "All" : `${above} of ${dms.length}`} models beat a bot that simply never folds.` : ""), "#spot-bench"]);
  }
  const S = formatsSummary(bench);
  if (S?.best.length) {
    items.push(["Cash vs. tournaments", formatsSentence(S) + (S.waiting.length ? ` Not yet measured: ${S.waiting.map((c) => `${c.format.short} ${PHASE_PLAIN[c.phase]}`).join(", ")}.` : ""), "#formats"]);
  }
  const A = arenaSummary(arena, book);
  if (A) {
    const tagRes = A.byTag.map((x) => x.p.bb100), st = A.dms.map((d) => A.get(d, "bot:station")?.bb100).filter((v) => v != null);
    let t = "";
    if (tagRes.length) t += `Against a solid regular, results range from ${signed(Math.min(...tagRes))} to ${signed(Math.max(...tagRes))} big blinds per 100 hands. `;
    if (st.length) t += `Against a player who never folds, from ${signed(Math.min(...st))} to ${signed(Math.max(...st))}: models punish weak opponents far more than they hold up against good ones.`;
    items.push(["Strong vs. weak opponents", t, "#arena"]);
  }
  const L = lunaSummary(bench, ctx.notes);
  if (L?.bestDev) {
    const d = L.bestDev.dev.diff.bb, t = L.bestDev.test?.diff?.bb;
    items.push([`What helped ${L.e.focusName}`, (ctx.notes?.luna?.takeaway) ?? `“${variantPlain(L.bestDev, bench)}” helped most on practice hands (${signed(d.mean)} per 100 hands); ` +
      (t ? (t.sig && t.mean < 0 ? "and it held up on fresh hands." : `on fresh hands the effect was ${signed(t.mean)} — not yet distinguishable from luck.`) : "the check on fresh hands is still running."), "#luna"]);
  }
  const el = $("#takeaways");
  if (!items.length) { el.hidden = true; return; }
  el.hidden = false;
  $("#tk-list").innerHTML = items.map(([h, t, href, featured]) => `<li${featured ? ` class="featured"` : ""}><h3>${esc(h)}</h3><p>${esc(t)}</p><a href="${href}">See the chart</a></li>`).join("");
}

// ── Methodology: simple and advanced additions ────────────
export function methodSimple(ctx) {
  const { bench, arena } = ctx;
  const formats = (bench?.formatInfo ?? []).map((f) => f.short).join(", ");
  $("#method-simple").innerHTML = `
    <div><h3>The yardstick: perfect play</h3><p>A poker solver works out the unexploitable strategy (“game-theory optimal”) for each situation. Every move a model makes is compared with the solver's best move, and we count what it costs in <strong>big blinds</strong> — the standard unit of poker winnings.</p></div>
    <div><h3>Three tests</h3><p><strong>Spots</strong>: single turn and river decisions. <strong>Full hands</strong>: every decision of real hands, before and after the flop. <strong>Arena</strong>: whole matches against bots that play like real opponents.</p></div>
    <div><h3>Formats</h3><p>${esc(formats || "Cash games and tournaments")}. Cash games are 100 big blinds deep; tournaments and Spin & Gos are shorter, so pushing all-in matters more. Tournament prize pressure is not modelled — chips count as chips.</p></div>
    <div><h3>Fair comparisons</h3><p>The models are AI “decision models”: they read the table and return a probability for each move. To test prompt ideas honestly we tuned on practice hands and only trusted results that held on <strong>fresh hands</strong>. Ranges around each number show how sure we are; overlapping ranges mean “too close to call”.</p></div>
    ${arena?.pairs?.length ? `<div><h3>The bots</h3><ul>${(arena.bots ?? []).map((b) => `<li><strong>${esc(b.title)}</strong> — ${esc(b.summary)}</li>`).join("")}</ul></div>` : ""}`;
}

export function methodAdvanced(ctx) {
  const { bench, arena } = ctx;
  const extra = document.createElement("div");
  extra.className = "method-extra full";
  const formats = (bench?.formatInfo ?? []).map((f) => `<li><strong>${esc(f.title)}</strong> — ${esc(f.summary)}</li>`).join("");
  const variants = (bench?.variants ?? []).map((v) => `<dt><code>${esc(v.id)}</code></dt><dd>${esc(v.summary)}</dd>`).join("");
  const th = bench?.thresholds;
  extra.innerHTML = `
    <div class="method-grid">
      <div><h3>Full-hand suites</h3><p>For each solve a flop is drawn for a scenario of the format (weighted towards BTN/CO vs BB single-raised pots), the full flop game is solved from the scenario's preflop ranges with DCFR, and K hands are dealt from those ranges and played to the end following the GTO strategy. <strong>Every decision of both players on flop, turn and river</strong> is recorded, so turn and river ranges are correctly narrowed and nothing is filtered as trivial. Flop trees depend on stack-to-pot ratio (explicit all-in below SPR 8, a second flop size below 3).</p>
        <p>bb/100 lost = 100 × mean over hands of the summed EV loss ÷ 2 (the model plays both seats), 95% CI with hands as the sampling unit. Losses are one-step deviations along the GTO line. Published: hands suites with ≥ ${th?.handsMinDecisions ?? 50} decisions, preflop suites with ≥ ${th?.preflopMinDecisions ?? 100}.</p></div>
      <div><h3>Preflop solver</h3><p>Heads-up preflop (blind vs blind; Spin & Go heads-up) solved by the core's preflop CFR. At ≤ 12bb it is an <strong>exact push/fold Nash</strong> equilibrium (all-in equities from a full evaluator). Deeper, a min-raise (≤ 30bb) or 2.5x tree with limps, one iso size, one 3-bet and 4-bet size and all-in; flop terminals are valued by an <strong>equity-realisation model</strong> (all-in equity scaled by position and SPR) rather than a postflop solve, so deep preflop EVs are approximate. Every preflop decision of each dealt hand is scored.</p></div>
      <div><h3>Formats</h3><ul>${formats}</ul><p>One format per suite; chip EV only — ICM (tournament payouts) is not modelled.</p></div>
      <div><h3>Dev / test protocol</h3><p>Experiments run on <code>eqbench bench split</code> halves of a hands suite, split by hand: configurations are compared on <strong>dev</strong> and only the chosen ones are run on the held-out <strong>test</strong> half. Differences are paired (same hands, same decisions) — much tighter than comparing two independent bb/100 estimates. Baselines on splits are borrowed from the parent suite.</p></div>
      <div class="full"><h3>Request variants</h3><dl class="metrics">${variants}</dl>
        <p>Derived players (<code>bench synth</code>) reuse stored answers with no API calls: <strong>temper</strong> raises probabilities to τ (τ = ∞ is argmax), <strong>ensemble</strong> averages several runs' probabilities, <strong>guardrail</strong> moves fold probability to call when a heuristic equity beats the price — that one is labelled <em>hybrid</em> because non-model information changes answers.</p></div>
      <div class="full"><h3>Confidence and agreement</h3><p><strong>Calibration</strong> pools every decision-model answer that returned probabilities (all suites, splits and variants; the free Mercury endpoint is merged with the paid one) and buckets it by the model's top probability; per bucket: share of answers, best-action rate (pick within 0.25% pot of the top EV) and mean EV loss % pot with a 95% CI. <strong>Agreement</strong> takes, per suite and variant, the decisions answered by at least three of Luna, Jev, Mercury, d1 and Clef; the plurality pick (ties → lowest action index) is scored like a player (“majority vote”). <strong>Escalation</strong> replaces Luna's pick with another model's when Luna's top probability is below a threshold. <strong>Bet-sizing share</strong> = EV loss where the chosen and best-EV actions are both bet/raise/all-in of different sizes ÷ total loss. Computed by the exporter (<code>Findings.swift</code>) into <code>bench.json</code>.</p></div>
      <div class="full"><h3>Who built this</h3><p>This project is 100% vibe-coded: the solver, the benchmark, the experiments and this site were all built by <strong>Claude Opus 5.5</strong> (medium effort) orchestrating subagents, from a human's high-level chat prompts.</p></div>
      <div class="full"><h3>Arena</h3><p>Complete heads-up hands, preflop to river, 100bb, in duplicate format (each deal played twice with seats swapped). Decision models play their top choice (argmax) or sample their distribution (“sampled”). bb/100 and all-in-EV bb/100 with 95% CIs over duplicate pairs; matches with < ${arena?.minHands ?? 100} hands and self-play are excluded. Bots:</p>
        <ul>${(arena?.bots ?? []).map((b) => `<li><strong>${esc(b.title)}</strong> (<code>${esc(b.id)}</code>) — ${esc(b.summary)}</li>`).join("")}</ul></div>
    </div>`;
  $("#method-body").appendChild(extra);
}
