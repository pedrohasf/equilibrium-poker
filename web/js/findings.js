// Cross-run findings: the Insights grid (data/insights.json + live numbers), the featured confidence
// (calibration) section and the cross-model agreement section. Data: bench.json → `calibration`, `agreement`.
import { esc, fmt, ttRows, bindTips, mount, md, isAdvanced } from "./util.js";
import { linear, niceTicks, dot } from "./charts.js";

const $ = (s) => document.querySelector(s);
const NS = 'xmlns="http://www.w3.org/2000/svg"';

// Fixed categorical order for the five core models (validated palette, see styles.css --m1…--m5).
const CORE_ORDER = ["openai/gpt-6-luna-decisions", "typesafe/jev-1.13", "inception/mercury-decide", "liquid/d1", "cloudflare/clef"];
const colorOf = (model) => { const i = CORE_ORDER.indexOf(model); return i >= 0 ? `var(--m${i + 1})` : "var(--muted)"; };
const pct0 = (x) => fmt.pct(x, 0);
const potPct = (x, d = 1) => fmt.pct(x, d);

// Coarse buckets (edges 0, .4, .6, .8, 1), shown from most to least sure.
const BUCKET_NAMES = ["Guessing", "Torn", "Fairly sure", "Very sure"];
const BUCKET_RANGES = ["under 40%", "40–60%", "60–80%", "80% or more"];
const BUCKET_ADV = ["< 0.4", "0.4–0.6", "0.6–0.8", "≥ 0.8"];

// ── Calibration helpers ───────────────────────────────────
function focusCal(bench) {
  const c = bench?.calibration;
  if (!c?.overall?.n) return null;
  return c.models.find((m) => m.model === c.focus) ?? c.overall;
}
const calName = (m) => m?.short ?? "the models";

/** "When Luna is very sure … only 54% … cost 3× more." */
export function calibrationSentence(m) {
  const b = m?.buckets;
  if (!b || b.length < 4 || !b[3].n || !b[1].n) return null;
  const sure = b[3], torn = b[1];
  const ratio = torn.lossPot / Math.max(sure.lossPot, 1e-9);
  const who = calName(m);
  return `When ${who} is very sure (80%+ on one move) it picks the best move <strong>${pct0(sure.best)}</strong> of the time; when it's torn (40–60%), only <strong>${pct0(torn.best)}</strong>` +
    (torn.best < 0.6 ? " — barely better than a coin flip" : "") +
    (ratio >= 1.5 ? ` — and those decisions cost <strong>${ratio.toFixed(ratio < 10 ? 0 : 0)}× more</strong>.` : ".");
}

// ── Agreement helpers ─────────────────────────────────────
function headlineGroup(bench) {
  const a = bench?.agreement;
  if (!a?.groups?.length) return null;
  return a.groups[a.headline ?? 0] ?? a.groups[0];
}
function levelLabel(l, plain = true) {
  if (l.agree === l.of) return plain ? `All ${l.of} agree` : `${l.agree}/${l.of}`;
  if (l.agree * 2 <= l.of) return plain ? `No majority (top pick ${l.agree} of ${l.of})` : `${l.agree}/${l.of}`;
  return plain ? `${l.agree} of ${l.of} agree` : `${l.agree}/${l.of}`;
}

// ── Insights ──────────────────────────────────────────────
function liveCard(card, bench) {
  const c = { ...card, isLive: false };
  if (card.live === "calibration") {
    const m = focusCal(bench);
    const s = calibrationSentence(m);
    if (m && s) {
      const b = m.buckets;
      Object.assign(c, {
        isLive: true,
        big: `${pct0(b[3].best)} vs ${pct0(b[1].best)}`,
        text: s.replace(/<\/?strong>/g, "").replace(/\.$/, "") + ` (${potPct(b[1].lossPot)} vs ${potPct(b[3].lossPot)} of the pot per decision).`,
        stats: `${m.name ?? "All models"}, top probability ` + [3, 2, 1, 0].map((i) => `${BUCKET_ADV[i]}: best ${pct0(b[i].best)} ± ${(b[i].bestCI * 100).toFixed(0)}, loss ${potPct(b[i].lossPot)} ± ${(b[i].lossPotCI * 100).toFixed(1)}% pot (n = ${fmt.int(b[i].n)})`).join("; ") + ".",
        n: `${fmt.int(m.n)} answers`,
        ci: "95% CI shown per bucket",
        suite: "All stored answers (every suite, split and variant)",
      });
    }
  } else if (card.live === "agreement") {
    const g = headlineGroup(bench);
    const all = g?.levels.find((l) => l.agree === l.of), split = g?.levels.find((l) => l.agree === Math.ceil((l.of + 1) / 2));
    if (g && all && split) {
      const best = g.players.find((p) => p.model === g.bestModel);
      Object.assign(c, {
        isLive: true,
        big: `${potPct(all.lossPot, 2)} vs ${potPct(split.lossPot, 2)}`,
        bigLabel: `of the pot lost: unanimous vs. split ${split.agree}–${split.of - split.agree}`,
        text: `Unanimous picks lost very little; when the models split ${split.agree}–${split.of - split.agree} they lost ${Math.round(split.lossPot / Math.max(all.lossPot, 1e-9))}× more. A simple majority vote ${g.majority.lossPot < best.lossPot ? "beat" : "did not beat"} the best single model (${potPct(g.majority.lossPot, 2)} vs ${potPct(best.lossPot, 2)}).`,
        stats: g.levels.map((l) => `${l.agree}/${l.of} agree on ${pct0(l.share)} (best ${pct0(l.best)}, ${potPct(l.lossPot, 2)} ± ${(l.lossPotCI * 100).toFixed(2)}% pot)`).join("; ") +
          `. Majority vote ${potPct(g.majority.lossPot, 2)} vs ${best.short} ${potPct(best.lossPot, 2)} pot (paired Δ ${(g.majorityVsBest.mean * 100).toFixed(2)} ± ${(g.majorityVsBest.ci * 100).toFixed(2)}).`,
        n: `${g.decisions} decisions × ${g.models.length} models`,
        ci: `vote − best Δ ±${(g.majorityVsBest.ci * 100).toFixed(2)}% pot`,
        suite: `${g.title}, ${g.variant}`,
      });
    }
  } else if (card.live === "sizing") {
    const g = headlineGroup(bench);
    const ps = g?.players.slice().sort((a, b) => b.sizingShare - a.sizingShare);
    const focus = g?.players.find((p) => p.model === g.focus);
    if (ps?.length && focus) {
      const low = ps[ps.length - 1];
      Object.assign(c, {
        isLive: true,
        big: pct0(focus.sizingShare),
        bigLabel: `of ${focus.short}'s loss: right move, wrong size`,
        text: `${focus.sizingShare > 0.25 ? "About a third" : pct0(focus.sizingShare)} of what ${focus.short} gives away comes from choosing to bet or raise correctly but with the wrong size. For ${low.short} it's only ${pct0(low.sizingShare)}.`,
        stats: "Share of EV loss where the chosen and best actions are both bet/raise/all-in of different sizes: " + ps.map((p) => `${p.short} ${pct0(p.sizingShare)}`).join(", ") + ".",
        n: `${g.decisions} decisions per model`,
        suite: `${g.title}, ${g.variant}`,
      });
    }
  }
  return c;
}

function miniBars(bench) {
  const m = focusCal(bench);
  if (!m) return "";
  const b = m.buckets;
  return `<div class="in-mini" aria-hidden="true">${[3, 2, 1].map((i) => `<div><i style="height:${Math.round(b[i].best * 100)}%"></i><span>${pct0(b[i].best)}</span><small>${BUCKET_NAMES[i]}</small></div>`).join("")}</div>`;
}

export function renderInsights(insights, bench) {
  const list = $("#in-list");
  const cards = insights?.cards ?? [];
  if (!cards.length) { $("#insights").hidden = true; return; }
  list.innerHTML = cards.map((raw, i) => {
    const c = liveCard(raw, bench);
    const rows = [["Stats", c.stats], ["Sample", c.n], ["95% CI", c.ci], ["Suite", c.suite]].filter(([, v]) => v);
    return `<li class="insight${c.featured ? " featured" : ""}" id="insight-${esc(c.id)}">
      <div class="in-top"><span class="in-num">${String(i + 1).padStart(2, "0")}</span>${c.isLive ? `<span class="live-tag adv" title="Computed from the current bench.json">live</span>` : ""}
        <a class="in-link" href="#insight-${esc(c.id)}" title="Copy a link to this insight" aria-label="Copy a link to this insight: ${esc(c.headline)}">#</a></div>
      <h3>${esc(c.headline)}</h3>
      <div class="in-hero"><p class="in-big${String(c.big).length > 9 ? " long" : ""}">${esc(c.big)}</p><p class="in-big-label">${esc(c.bigLabel ?? "")}</p></div>
      ${c.featured ? miniBars(bench) : ""}
      <p class="in-text">${esc(c.text)}</p>
      ${rows.length ? `<dl class="in-stats adv">${rows.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${md(v).replace(/^<p>|<\/p>$/g, "")}</dd>`).join("")}</dl>` : ""}
      <a class="in-ev" href="${esc(c.href ?? "#")}">${esc(c.evidence ?? "See the evidence")} →</a>
    </li>`;
  }).join("");
  list.addEventListener("click", async (e) => {
    const a = e.target.closest(".in-link");
    if (!a) return;
    e.preventDefault();
    const url = new URL(a.getAttribute("href"), location.href).href;
    history.replaceState(null, "", a.getAttribute("href"));
    highlight(a.closest(".insight"));
    try { await navigator.clipboard.writeText(url); a.dataset.copied = "1"; setTimeout(() => delete a.dataset.copied, 1600); } catch {}
  });
  const fromHash = () => {
    if (!location.hash.startsWith("#insight-")) return;
    const el = document.getElementById(location.hash.slice(1));
    if (el) { el.scrollIntoView({ block: "center" }); highlight(el); }
  };
  window.addEventListener("hashchange", fromHash);
  fromHash();
}
function highlight(el) {
  if (!el) return;
  el.classList.remove("flash");
  void el.offsetWidth;
  el.classList.add("flash");
}

// ── Featured: confidence ──────────────────────────────────
export function renderConfidence(bench) {
  const cal = bench?.calibration;
  const sec = $("#confidence");
  if (!cal?.overall?.n) { sec.hidden = true; return; }
  const focus = focusCal(bench);
  const state = { model: focus.model ?? "all" };
  const pickCal = () => (state.model === "all" ? { ...cal.overall, short: "all models", name: "All decision models" } : cal.models.find((m) => m.model === state.model) ?? focus);

  $("#cf-def").innerHTML = `Every decision-model answer that came with action probabilities, across every stored suite, split and prompt variant (${fmt.int(cal.overall.n)} answers; free endpoints merged with the paid model). Confidence = the model's top probability; buckets are lower-inclusive (0.6 ≤ p &lt; 0.8). Best move = pick within 0.25% pot of the top EV. Loss = mean EV loss of the pick, % pot, ± 95% CI.`;

  // Controls: focus vs all (both modes) + every model (advanced).
  const ctrl = $("#cf-controls");
  const opts = [[focus.model, focus.short], ["all", "All models pooled"]];
  ctrl.innerHTML = `<div class="seg simple" role="radiogroup" aria-label="Model">${opts.map(([v, t], i) => `<button type="button" role="radio" aria-checked="${i === 0}" data-v="${esc(v)}">${esc(t)}</button>`).join("")}</div>` +
    `<label class="pick adv">Model <select>${cal.models.map((m) => `<option value="${esc(m.model)}"${m.model === focus.model ? " selected" : ""}>${esc(m.name)} · n = ${fmt.int(m.n)}</option>`).join("")}<option value="all">All decision models · n = ${fmt.int(cal.overall.n)}</option></select></label>`;
  ctrl.querySelector(".seg").addEventListener("click", (e) => {
    const b = e.target.closest("button");
    if (!b) return;
    for (const x of ctrl.querySelectorAll(".seg button")) x.setAttribute("aria-checked", String(x === b));
    state.model = b.dataset.v; ctrl.querySelector("select").value = b.dataset.v; draw();
  });
  ctrl.querySelector("select").addEventListener("change", (e) => {
    state.model = e.target.value;
    for (const x of ctrl.querySelectorAll(".seg button")) x.setAttribute("aria-checked", String(x.dataset.v === state.model));
    draw();
  });

  const tips = {};
  bindTips($("#cf-chart"), (k) => tips[k]);
  function draw() {
    const m = pickCal();
    const b = m.buckets;
    $("#cf-headline").innerHTML = `<span class="simple">${calibrationSentence(m) ?? ""}</span><span class="adv">${esc(m.name)}: top probability ≥ 0.8 → best ${pct0(b[3].best)} ± ${(b[3].bestCI * 100).toFixed(0)}, ${potPct(b[3].lossPot, 2)} pot; 0.4–0.6 → ${pct0(b[1].best)} ± ${(b[1].bestCI * 100).toFixed(0)}, ${potPct(b[1].lossPot, 2)} pot (n = ${fmt.int(m.n)}, ECE ${m.ece.toFixed(3)}).</span>`;
    $("#cf-chart-sub").innerHTML = `<span class="simple">Tall green bars: how often ${esc(calName(m))}'s favourite move was the best one. Gold bars below: what each decision cost on average, in % of the pot. <strong>Dashed line = a coin flip.</strong></span>` +
      `<span class="adv">Bar = best-action rate (± 95% CI in tooltip); gold = mean EV loss % pot (bucket with &lt; 50 answers shown faded). Share of answers under each bucket. ${esc(m.name)}, n = ${fmt.int(m.n)}.</span>`;
    const shown = [3, 2, 1, 0].filter((i) => b[i].n > 0);
    const solid = shown.filter((i) => b[i].n >= 50);
    const costMax = Math.max(...(solid.length ? solid : shown).map((i) => b[i].lossPot)) * 1.12 || 0.01;
    $("#cf-bars").innerHTML = `<div class="conf-cols" role="list">${shown.map((i) => {
      const x = b[i], rare = x.n < 50, off = x.lossPot > costMax;
      tips[`cf${i}`] = `<b>${BUCKET_NAMES[i]} (${BUCKET_RANGES[i]})</b>${ttRows([["Picked the best move", `${pct0(x.best)} ± ${(x.bestCI * 100).toFixed(0)}`], ["Lost per decision", `${potPct(x.lossPot, 2)} ± ${(x.lossPotCI * 100).toFixed(2)}% pot`], ["Share of decisions", fmt.pct(x.share, 1)], ["Answers", fmt.int(x.n)], ["Mean confidence", pct0(x.meanTop)]])}`;
      return `<div class="conf-col${rare ? " rare" : ""}" role="listitem" tabindex="0" data-tip="cf${i}" aria-label="${BUCKET_NAMES[i]}, ${BUCKET_RANGES[i]} on one move: best move ${pct0(x.best)} of the time, ${potPct(x.lossPot)} of the pot lost per decision, ${fmt.pct(x.share, 0)} of decisions.">
        <div class="conf-pct">${pct0(x.best)}</div>
        <div class="conf-bar"><i style="height:${(x.best * 100).toFixed(1)}%"></i>${i === 3 ? `<span class="coin-l">coin flip</span>` : ""}</div>
        <div class="conf-name">${BUCKET_NAMES[i]}</div>
        <div class="conf-range"><span class="simple">${BUCKET_RANGES[i]} on one move</span><span class="adv">top p ${BUCKET_ADV[i]}</span></div>
        <div class="conf-cost"><span class="cost-bar"><i style="width:${Math.min(100, (x.lossPot / costMax) * 100).toFixed(1)}%"></i>${off ? `<em>▸</em>` : ""}</span><b>${potPct(x.lossPot, x.lossPot < 0.1 ? 1 : 0)}</b><small>of the pot lost</small></div>
        <div class="conf-share">${rare ? `rare: ${fmt.int(x.n)} answers` : `${fmt.pct(x.share, 0)} of decisions`}</div>
      </div>`;
    }).join("")}</div>`;
    drawTables();
  }
  draw();

  // Advanced: reliability diagram, escalation, tables.
  const relTips = {};
  const relState = { all: false };
  const relFig = $("#cf-rel");
  const relModels = () => cal.models.filter((m) => (relState.all ? true : CORE_ORDER.includes(m.model)) && m.n >= 100);
  $("#cf-rel-legend").innerHTML = `<label class="toggle"><input type="checkbox" id="cf-rel-all"> All models</label>` +
    CORE_ORDER.map((id) => cal.models.find((m) => m.model === id)).filter(Boolean).map((m) => `<span><i style="background:${colorOf(m.model)}"></i>${esc(m.short)}</span>`).join("") + `<span><i style="background:var(--muted)"></i>other</span>`;
  const relDraw = mount(relFig.querySelector(".plot"), (el) => {
    const W = Math.max(280, el.clientWidth), H = Math.min(420, Math.max(260, W * 0.72));
    const L = 44, R = 64, T = 14, B = 40;
    const x = linear(0.3, 1, L, W - R), y = linear(0.2, 1, H - B, T);
    let s = `<svg ${NS} viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-label="Reliability diagram: mean top probability against best-move rate per model.">`;
    for (const t of niceTicks(0.3, 1, 7)) s += `<line class="grid" x1="${x(t)}" x2="${x(t)}" y1="${T}" y2="${H - B}"/><text class="tick-t" x="${x(t)}" y="${H - B + 16}" text-anchor="middle">${Math.round(t * 100)}%</text>`;
    for (const t of niceTicks(0.2, 1, 4)) s += `<line class="grid" x1="${L}" x2="${W - R}" y1="${y(t)}" y2="${y(t)}"/><text class="tick-t" x="${L - 6}" y="${y(t) + 4}" text-anchor="end">${Math.round(t * 100)}%</text>`;
    s += `<line x1="${x(0.3)}" y1="${y(0.3)}" x2="${x(1)}" y2="${y(1)}" stroke="var(--ink-2)" stroke-dasharray="4 4" opacity=".6"/>`;
    s += `<text class="tick-t" x="${x(0.93)}" y="${y(0.97) - 6}" text-anchor="end">calibrated</text>`;
    s += `<text class="tick-t" x="${(L + W - R) / 2}" y="${H - 6}" text-anchor="middle">model's top probability (mean in bin)</text>`;
    s += `<text class="tick-t" transform="translate(11 ${(T + H - B) / 2}) rotate(-90)" text-anchor="middle">picked the best move</text>`;
    const ms = relModels().sort((a, b) => (CORE_ORDER.includes(a.model) ? 1 : 0) - (CORE_ORDER.includes(b.model) ? 1 : 0));
    const labels = [];
    for (const m of ms) {
      const pts = m.curve.filter((b) => b.n >= 20);
      if (!pts.length) continue;
      const col = colorOf(m.model), core = CORE_ORDER.includes(m.model);
      s += `<polyline fill="none" stroke="${col}" stroke-width="${core ? 2 : 1.25}" opacity="${core ? 1 : 0.55}" points="${pts.map((b) => `${x(b.meanTop)},${y(Math.max(0.2, b.best))}`).join(" ")}"/>`;
      for (const b of pts) {
        const k = `rel:${m.model}:${b.lo}`;
        relTips[k] = `<b>${esc(m.name)}</b>${ttRows([["Top probability", `${b.lo}–${b.hi} (mean ${pct0(b.meanTop)})`], ["Best move", `${pct0(b.best)} ± ${(b.bestCI * 100).toFixed(0)}`], ["Loss", `${potPct(b.lossPot, 2)} pot`], ["Answers", fmt.int(b.n)]])}`;
        const r = Math.max(4, Math.min(9, Math.sqrt(b.n) / 5));
        s += `<g class="row"><circle cx="${x(b.meanTop)}" cy="${y(Math.max(0.2, b.best))}" r="${r}" fill="${col}" stroke="var(--surface)" stroke-width="2" opacity="${core ? 1 : 0.6}"/><circle class="hit" cx="${x(b.meanTop)}" cy="${y(Math.max(0.2, b.best))}" r="${r + 5}" tabindex="0" data-tip="${esc(k)}"/></g>`;
      }
      if (core) { const last = pts[pts.length - 1]; labels.push({ y: y(Math.max(0.2, last.best)), x: x(last.meanTop) + 10, t: m.short }); }
    }
    labels.sort((a, b) => a.y - b.y);
    for (let i = 1; i < labels.length; i++) if (labels[i].y - labels[i - 1].y < 13) labels[i].y = labels[i - 1].y + 13;
    for (const l of labels) s += `<text class="val" x="${Math.min(l.x, W - R + 8)}" y="${l.y + 4}">${esc(l.t)}</text>`;
    el.innerHTML = s + `</svg>`;
  });
  $("#cf-rel-all").addEventListener("change", (e) => { relState.all = e.target.checked; relDraw?.(); });
  bindTips(relFig, (k) => relTips[k]);

  // Escalation simulation.
  const escGroups = (bench.agreement?.groups ?? []).filter((g) => g.escalation?.length && g.focusLossPot != null);
  const escFig = $("#cf-esc");
  if (!escGroups.length) escFig.hidden = true;
  else {
    let gi = escGroups.findIndex((g) => g.variant === "nuts");
    if (gi < 0) gi = 0;
    for (let i = 0; i < escGroups.length; i++) if (escGroups[i].variant === "nuts" && escGroups[i].decisions > escGroups[gi].decisions) gi = i;
    $("#cf-esc-pick").innerHTML = `<label class="pick">Suite <select>${escGroups.map((g, i) => `<option value="${i}"${i === gi ? " selected" : ""}>${esc(g.title)} · ${esc(g.variant)} · ${g.decisions} decisions</option>`).join("")}</select></label>`;
    $("#cf-esc-pick select").addEventListener("change", (e) => { gi = +e.target.value; escDraw?.(); });
    const escTips = {};
    const escDraw = mount(escFig.querySelector(".plot"), (el) => {
      const g = escGroups[gi];
      const focusShort = g.players.find((p) => p.model === g.focus)?.short ?? "focus";
      const helpers = g.players.filter((p) => p.model !== g.focus);
      $("#cf-esc-sub").innerHTML = `${esc(focusShort)} hands a decision to one other model when its top probability is below the threshold (share of decisions handed over in brackets). Mean EV loss % pot of the combined player on the ${g.decisions} decisions every model answered; dashed = ${esc(focusShort)} alone (${potPct(g.focusLossPot, 2)}). <strong>Lower is better.</strong>`;
      $("#cf-esc-legend").innerHTML = helpers.map((p) => `<span><i style="background:${colorOf(p.model)}"></i>${esc(p.short)}</span>`).join("");
      const W = Math.max(280, el.clientWidth), H = 280, L = 48, R = 56, T = 14, B = 44;
      const th = g.escalation.map((e) => e.threshold);
      const vals = g.escalation.flatMap((e) => Object.values(e.lossPot)).concat(g.focusLossPot);
      const lo = Math.min(...vals) * 0.92, hi = Math.max(...vals) * 1.05;
      const x = linear(th[0], th[th.length - 1], L, W - R), y = linear(lo, hi, H - B, T);
      let s = `<svg ${NS} viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-label="Escalation simulation: loss versus escalation threshold per helper model.">`;
      for (const t of niceTicks(lo * 100, hi * 100, 4)) s += `<line class="grid" x1="${L}" x2="${W - R}" y1="${y(t / 100)}" y2="${y(t / 100)}"/><text class="tick-t" x="${L - 6}" y="${y(t / 100) + 4}" text-anchor="end">${t}%</text>`;
      for (const e of g.escalation) s += `<text class="tick-t" x="${x(e.threshold)}" y="${H - B + 16}" text-anchor="middle">&lt;${e.threshold}</text><text class="tick-t" x="${x(e.threshold)}" y="${H - B + 30}" text-anchor="middle">(${fmt.pct(e.escalated, e.escalated > 0 && e.escalated < 0.1 ? 1 : 0)})</text>`;
      s += `<line x1="${L}" x2="${W - R}" y1="${y(g.focusLossPot)}" y2="${y(g.focusLossPot)}" stroke="var(--ink-2)" stroke-dasharray="5 4"/><text class="val" x="${W - R + 6}" y="${y(g.focusLossPot) + 4}">${esc(focusShort)}</text>`;
      for (const p of helpers) {
        const pts = g.escalation.map((e) => [x(e.threshold), y(e.lossPot[p.model])]);
        s += `<polyline fill="none" stroke="${colorOf(p.model)}" stroke-width="2" points="${pts.map((q) => q.join(",")).join(" ")}"/>`;
        g.escalation.forEach((e, i) => {
          const k = `esc:${p.model}:${e.threshold}`;
          escTips[k] = `<b>${esc(focusShort)} → ${esc(p.short)} below ${e.threshold}</b>${ttRows([["Handed over", pct0(e.escalated)], ["Loss", `${potPct(e.lossPot[p.model], 2)} pot`], [`${focusShort} alone`, `${potPct(g.focusLossPot, 2)} pot`]])}`;
          s += `<g class="row">${dot(pts[i][0], pts[i][1], colorOf(p.model), 4)}<circle class="hit" cx="${pts[i][0]}" cy="${pts[i][1]}" r="9" tabindex="0" data-tip="${esc(k)}"/></g>`;
        });
      }
      el.innerHTML = s + `</svg>`;
    });
    bindTips(escFig, (k) => escTips[k]);
  }

  function drawTables() {
    const cell = (b) => (b.n ? `${pct0(b.best)} <span class="dash">±${(b.bestCI * 100).toFixed(0)}</span><br>${potPct(b.lossPot, 2)} <span class="dash">±${(b.lossPotCI * 100).toFixed(2)} [${fmt.int(b.n)}]</span>` : `<span class="dash">–</span>`);
    const head = `<tr><th class="l" scope="col">Model</th><th scope="col">Answers</th>${[3, 2, 1, 0].map((i) => `<th scope="col">top p ${BUCKET_ADV[i]}<br>best · loss % pot</th>`).join("")}<th scope="col">Mean top p</th><th scope="col">Best<br>overall</th><th scope="col">ECE</th></tr>`;
    const row = (m, label, sub) => `<tr><td class="name l"><span class="n">${esc(label)}</span><span class="m">${esc(sub)}</span></td><td>${fmt.int(m.n)}</td>${[3, 2, 1, 0].map((i) => `<td>${cell(m.buckets[i])}</td>`).join("")}<td>${pct0(m.meanTop)}</td><td>${pct0(m.best)}</td><td>${m.ece.toFixed(3)}</td></tr>`;
    $("#cf-table thead").innerHTML = head;
    $("#cf-table tbody").innerHTML = cal.models.map((m) => row(m, m.name, m.model)).join("") + row(cal.overall, "All decision models", "pooled");
    $("#cf-foot").innerHTML = `Best = pick within 0.25% pot of the top EV, ± 95% CI (normal approximation); loss = mean EV loss of the pick, % pot, ± 95% CI [answers]. ECE = Σ (n<sub>bin</sub>/n) · |mean top p − best rate| over bins 0–0.4, 0.4–0.5, …, 0.9–1. “Best” counts every action within tolerance, so a model can be right more often than its top probability on near-tied spots.`;
    const fv = (cal.variants ?? []).filter((v) => v.model === cal.focus);
    $("#cf-var-title").textContent = `${focus.name ?? "Focus model"} by prompt variant`;
    $("#cf-var thead").innerHTML = head.replace("Model", "Variant");
    $("#cf-var tbody").innerHTML = fv.length ? fv.map((v) => row(v, v.variant, `${v.short}`)).join("") : `<tr><td class="l" colspan="9">No variant with ≥ 100 answers.</td></tr>`;
  }
  document.addEventListener("eq:mode", () => { relDraw?.(); });
}

// ── Agreement ─────────────────────────────────────────────
function hbars(rows, { max, fmtV, color = "var(--s2)" }) {
  return `<div class="hbars" role="list">${rows.map((r) => `<div class="hbar${r.strong ? " strong" : ""}" role="listitem" tabindex="0"${r.tip ? ` data-tip="${esc(r.tip)}"` : ""}>
    <span class="hb-l">${r.dotColor ? `<i style="background:${r.dotColor}"></i>` : ""}${esc(r.label)}</span>
    <span class="hb-t"><i style="width:${Math.max(1, Math.min(100, (r.v / max) * 100)).toFixed(1)}%;background:${r.color ?? color}"></i></span>
    <b>${esc(fmtV(r.v))}</b></div>`).join("")}</div>`;
}

export function renderAgreement(bench) {
  const a = bench?.agreement;
  const sec = $("#agreement");
  if (!a?.groups?.length) { sec.hidden = true; return; }
  let gi = a.headline ?? 0;
  const groupSel = $("#ag-pick");
  groupSel.innerHTML = `<label class="pick">Suite <select>${a.groups.map((g, i) => `<option value="${i}"${i === gi ? " selected" : ""}>${esc(g.title)} · ${esc(g.variant)} · ${g.models.length} models · ${g.decisions} decisions</option>`).join("")}</select></label>`;
  groupSel.querySelector("select").addEventListener("change", (e) => { gi = +e.target.value; draw(); });
  $("#ag-def").innerHTML = esc(a.definition);
  const tips = {};
  for (const id of ["#ag-chart", "#ag-vote", "#ag-sizing", "#ag-players"]) bindTips($(id), (k) => tips[k]);

  function draw() {
    const adv = isAdvanced();
    const g = a.groups[adv ? gi : a.headline ?? 0];
    const names = g.models.map((m) => m.short).join(", ");
    const all = g.levels.find((l) => l.agree === l.of);
    const best = g.players.find((p) => p.model === g.bestModel);
    const voteWins = g.majority.lossPot < best.lossPot;
    const split = g.levels.find((l) => l.agree === Math.ceil((l.of + 1) / 2));
    $("#ag-headline").innerHTML = `<span class="simple">${all ? `When all ${g.models.length} models agree (${pct0(all.share)} of the time), they lose only <strong>${potPct(all.lossPot, 2)}</strong> of the pot per decision` : ""}` +
      (split && all ? `; when they split ${split.agree}–${split.of - split.agree}, <strong>${potPct(split.lossPot, 2)}</strong>.` : ".") +
      ` A simple majority vote ${voteWins ? "beat" : "did not beat"} the best single model, ${esc(best.short)} (${potPct(g.majority.lossPot, 2)} vs ${potPct(best.lossPot, 2)}).</span>` +
      `<span class="adv">${esc(g.title)} (${esc(g.variant)}), ${g.decisions} decisions answered by ${esc(names)}. Majority vote ${potPct(g.majority.lossPot, 2)} ± ${(g.majority.lossPotCI * 100).toFixed(2)} vs best single (${esc(best.short)}) ${potPct(best.lossPot, 2)} ± ${(best.lossPotCI * 100).toFixed(2)}% pot; paired Δ ${(g.majorityVsBest.mean * 100).toFixed(2)} ± ${(g.majorityVsBest.ci * 100).toFixed(2)}${g.majorityVsBest.sig ? " (significant)" : " (not significant)"}.</span>`;
    $("#ag-chart-sub").innerHTML = `<span class="simple">${esc(names)} on the same ${g.decisions} ${g.title.includes("spot") ? "spots" : "decisions"}. Gold bar = share of the pot the move most models chose gave away on average.</span><span class="adv">Plurality pick per decision (ties → lowest action index). Share of decisions, best-action rate and mean loss % pot ± 95% CI of the plurality pick.</span>`;
    const maxL = Math.max(...g.levels.map((l) => l.lossPot)) * 1.1 || 0.01;
    $("#ag-levels").innerHTML = g.levels.map((l) => {
      tips[`ag:${l.agree}`] = `<b>${levelLabel(l)}</b>${ttRows([["Share of decisions", pct0(l.share)], ["Decisions", String(l.n)], ["Shared pick was best", pct0(l.best)], ["Lost per decision", `${potPct(l.lossPot, 2)} ± ${(l.lossPotCI * 100).toFixed(2)}% pot`]])}`;
      return `<div class="agree-row" tabindex="0" data-tip="ag:${l.agree}">
        <div class="ag-who"><span class="ag-dots" aria-hidden="true">${Array.from({ length: l.of }, (_, i) => `<i class="${i < l.agree ? "on" : ""}"></i>`).join("")}</span><span class="ag-l">${esc(levelLabel(l))}</span><span class="ag-s">${pct0(l.share)} of ${g.title.includes("spot") ? "spots" : "decisions"} · best move ${pct0(l.best)}</span></div>
        <div class="ag-cost"><span class="cost-bar"><i style="width:${((l.lossPot / maxL) * 100).toFixed(1)}%"></i></span><b>${potPct(l.lossPot, 2)}</b></div>
      </div>`;
    }).join("");

    // Vote vs models.
    const players = g.players.slice().sort((x, y) => x.lossPot - y.lossPot);
    const rows = [{ label: "Majority vote", v: g.majority.lossPot, strong: true, color: "var(--s1)", tip: "ag:vote" }]
      .concat((adv ? players : [best]).map((p) => ({ label: adv ? p.short : `Best single model (${p.short})`, v: p.lossPot, dotColor: colorOf(p.model), tip: `ag:p:${p.model}` })));
    tips["ag:vote"] = `<b>Majority vote</b>${ttRows([["Loss", `${potPct(g.majority.lossPot, 2)} ± ${(g.majority.lossPotCI * 100).toFixed(2)}% pot`], ["Best move", pct0(g.majority.best)]])}`;
    for (const p of g.players) tips[`ag:p:${p.model}`] = `<b>${esc(p.name)}</b>${ttRows([["Loss", `${potPct(p.lossPot, 2)} ± ${(p.lossPotCI * 100).toFixed(2)}% pot`], ["Best move", pct0(p.best)], ["Agrees with the majority", pct0(p.agreesWithMajority)], ["Loss from bet sizing", pct0(p.sizingShare)]])}`;
    $("#ag-vote .plot").innerHTML = hbars(rows, { max: Math.max(...rows.map((r) => r.v)) * 1.08, fmtV: (v) => potPct(v, 2) });

    // Advanced: per-model table and sizing.
    $("#ag-players thead").innerHTML = `<tr><th class="l" scope="col">Player</th><th scope="col">Loss % pot ± CI</th><th scope="col">Best action</th><th scope="col">Agrees with<br>majority</th><th scope="col">Loss from<br>bet sizing</th></tr>`;
    $("#ag-players tbody").innerHTML = `<tr class="star"><td class="name l"><span class="n">Majority vote</span><span class="m">plurality of ${g.models.length}</span></td><td>${potPct(g.majority.lossPot, 2)} <span class="dash">±${(g.majority.lossPotCI * 100).toFixed(2)}</span></td><td>${pct0(g.majority.best)}</td><td>–</td><td>–</td></tr>` +
      players.map((p) => `<tr><td class="name l"><span class="n">${esc(p.name)}</span><span class="m">${esc(p.model)}</span></td><td>${potPct(p.lossPot, 2)} <span class="dash">±${(p.lossPotCI * 100).toFixed(2)}</span></td><td>${pct0(p.best)}</td><td>${pct0(p.agreesWithMajority)}</td><td>${pct0(p.sizingShare)}</td></tr>`).join("");
    const sz = g.players.slice().sort((x, y) => y.sizingShare - x.sizingShare);
    $("#ag-sizing-sub").innerHTML = `${esc(g.title)} (${esc(g.variant)}). Chosen and best-EV actions both bet / raise / all-in, but different sizes; share of the model's total EV loss.`;
    $("#ag-sizing .plot").innerHTML = hbars(sz.map((p) => ({ label: p.short, v: p.sizingShare, dotColor: colorOf(p.model), tip: `ag:p:${p.model}` })), { max: Math.max(0.05, ...sz.map((p) => p.sizingShare)) * 1.1, fmtV: pct0 });
  }
  draw();
  document.addEventListener("eq:mode", draw);

  // Every suite table.
  $("#ag-groups thead").innerHTML = `<tr><th class="l" scope="col">Suite · variant</th><th scope="col">Models</th><th scope="col">Decisions</th><th class="l" scope="col">Agreement levels: share · best · loss % pot</th><th scope="col">Majority<br>vote</th><th scope="col">Best single</th><th scope="col">Vote − best<br>paired Δ</th></tr>`;
  $("#ag-groups tbody").innerHTML = a.groups.map((g) => {
    const b = g.players.find((p) => p.model === g.bestModel);
    return `<tr><td class="name l"><span class="n">${esc(g.title)}</span><span class="m">${esc(g.variant)} · ${esc(g.key ?? g.suite)}</span></td><td>${g.models.map((m) => esc(m.short)).join(", ")}</td><td>${g.decisions}</td>` +
      `<td class="l">${g.levels.map((l) => `${l.agree}/${l.of}: ${pct0(l.share)} · ${pct0(l.best)} · ${potPct(l.lossPot, 2)}`).join("<br>")}</td>` +
      `<td>${potPct(g.majority.lossPot, 2)}</td><td>${esc(b.short)} ${potPct(b.lossPot, 2)}</td><td class="${g.majorityVsBest.sig ? (g.majorityVsBest.mean < 0 ? "good-t" : "bad-t") : ""}">${(g.majorityVsBest.mean * 100).toFixed(2)} ± ${(g.majorityVsBest.ci * 100).toFixed(2)}</td></tr>`;
  }).join("");
  $("#ag-foot").innerHTML = `Per suite and prompt variant, the decisions every listed model answered (a model is included when it answered at least half as many decisions as the most complete one; the <code>:free</code> Mercury endpoint counts as Mercury). Paired Δ in % pot, 95% CI; green = majority vote significantly better.`;
}

/** Extra takeaways (simple view), featured first. */
export function findingTakeaways(bench) {
  const out = [];
  const m = focusCal(bench);
  const s = calibrationSentence(m);
  if (s) out.push(["The models know when they're unsure", s.replace(/<\/?strong>/g, ""), "#confidence", true]);
  const g = headlineGroup(bench);
  const all = g?.levels.find((l) => l.agree === l.of);
  if (g && all) {
    const best = g.players.find((p) => p.model === g.bestModel);
    out.push([`When all ${g.models.length} agree`, `Unanimous picks lost ${potPct(all.lossPot, 2)} of the pot per decision; a majority vote of the ${g.models.length} models (${potPct(g.majority.lossPot, 2)}) ${g.majority.lossPot < best.lossPot ? "beat" : "did not beat"} the best single model (${potPct(best.lossPot, 2)}).`, "#agreement"]);
  }
  return out;
}
