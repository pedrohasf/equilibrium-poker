// Hand-made SVG charts (no dependencies). Every chart re-renders on resize.
import { esc, fmt, ttRows, bindTips, shortName } from "./util.js";

const NS = 'xmlns="http://www.w3.org/2000/svg"';

export function linear(d0, d1, r0, r1) {
  const f = (v) => r0 + ((v - d0) / (d1 - d0 || 1)) * (r1 - r0);
  f.domain = [d0, d1];
  return f;
}
function logScale(d0, d1, r0, r1) {
  const l0 = Math.log10(d0), l1 = Math.log10(d1);
  const f = (v) => r0 + ((Math.log10(Math.max(v, d0)) - l0) / (l1 - l0 || 1)) * (r1 - r0);
  f.domain = [d0, d1];
  return f;
}
export function niceTicks(lo, hi, count = 5) {
  const span = hi - lo, raw = span / count;
  const mag = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => span / s <= count) ?? raw;
  const out = [];
  for (let v = Math.ceil(lo / step) * step; v <= hi + 1e-9; v += step) out.push(+v.toFixed(10));
  return out;
}
function logTicks(lo, hi) {
  const out = [];
  for (let e = Math.floor(Math.log10(lo)); e <= Math.ceil(Math.log10(hi)); e++) {
    for (const m of [1, 2, 5]) { const v = m * 10 ** e; if (v >= lo * 0.999 && v <= hi * 1.001) out.push(v); }
  }
  return out;
}
export const textWidth = (s, px = 12) => s.length * px * 0.56;

/**
 * Rows chart: one row per player, a label column, a shared x axis on top, and per-row marks.
 * opts: { el, rows:[{key,label,base?,tip}], x:{lo,hi,log?,fmt,ticks?}, marks(row, x, cy) → svg, refs?:[{v,label}], aria }
 */
export function rowsChart(el, opts) {
  if (!el.clientWidth) return; // hidden (other view mode): drawn when it becomes visible
  const W = Math.max(280, el.clientWidth);
  const narrow = W < 520;
  const rowH = opts.rowH ?? 30;
  const labelW = Math.min(opts.labelW ?? 190, narrow ? 112 : 999);
  const right = opts.right ?? 54;
  const top = opts.refs?.length ? 42 : 22;
  const H = top + opts.rows.length * rowH + 8;
  const x = (opts.x.log ? logScale : linear)(opts.x.lo, opts.x.hi, labelW + 8, W - right);
  const ticks = opts.x.ticks ?? (opts.x.log ? logTicks(opts.x.lo, opts.x.hi) : niceTicks(opts.x.lo, opts.x.hi, narrow ? 4 : 6));
  let s = `<svg ${NS} viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-label="${esc(opts.aria)}">`;
  for (const t of ticks) {
    const tx = x(t);
    s += `<line class="grid" x1="${tx}" x2="${tx}" y1="${top - 6}" y2="${H - 6}"/>`;
    s += `<text class="tick-t" x="${tx}" y="${top - 12}" text-anchor="middle">${esc(opts.x.fmt(t))}</text>`;
  }
  if (opts.zero != null && opts.zero >= opts.x.lo && opts.zero <= opts.x.hi) {
    s += `<line class="axis" x1="${x(opts.zero)}" x2="${x(opts.zero)}" y1="${top - 6}" y2="${H - 6}" stroke-width="1.5"/>`;
  }
  // Reference lines (baselines), labels staggered to avoid collisions.
  let lastRefX = -1e9, lane = 0;
  for (const r of (opts.refs ?? []).slice().sort((a, b) => a.v - b.v)) {
    const rx = x(r.v);
    if (rx < labelW || rx > W - 4) continue;
    lane = rx - lastRefX < textWidth(r.label, 10.5) + 8 ? (lane + 1) % 2 : 0;
    lastRefX = rx;
    const ty = 10 + lane * 12;
    s += `<line class="ref" x1="${rx}" x2="${rx}" y1="${ty + 3}" y2="${H - 6}"/>`;
    const anchor = rx > W - 60 ? "end" : "middle";
    s += `<text class="ref-t" x="${rx}" y="${ty}" text-anchor="${anchor}">${esc(r.label)}</text>`;
  }
  opts.rows.forEach((row, i) => {
    const cy = top + i * rowH + rowH / 2;
    if (row.header) {
      s += `<text class="grp" x="4" y="${cy + 8}">${esc(row.label)}</text><line class="grid" x1="4" x2="${W - 4}" y1="${cy + 13}" y2="${cy + 13}"/>`;
      return;
    }
    let label = narrow || opts.short ? row.short ?? row.label : row.label;
    const maxChars = Math.floor((labelW - 4) / 6.6);
    if (label.length > maxChars) label = label.slice(0, maxChars - 1) + "…";
    s += `<g class="row">`;
    s += `<rect class="hit" x="0" y="${cy - rowH / 2}" width="${W}" height="${rowH}" tabindex="0" data-tip="${esc(row.key)}" aria-label="${esc(row.aria ?? row.label)}"/>`;
    s += `<text class="lab${row.base ? " base" : ""}${row.strong ? " strong" : ""}" x="${labelW}" y="${cy + 4}" text-anchor="end">${esc(label)}</text>`;
    s += opts.marks(row, x, cy);
    s += `</g>`;
  });
  s += `</svg>`;
  el.innerHTML = s;
}

export const dot = (cx, cy, color, r = 5, hollow = false) =>
  `<circle cx="${cx}" cy="${cy}" r="${r}" fill="${hollow ? "var(--surface)" : color}" stroke="${hollow ? color : "var(--surface)"}" stroke-width="2"/>` +
  (hollow ? "" : "");

// ── Individual charts ─────────────────────────────────────

export function renderCharts(data, root) {
  const players = data.players;
  const dms = players.filter((p) => p.kind === "decisionModel").sort((a, b) => b.overall.score - a.overall.score);
  const base = Object.fromEntries(players.filter((p) => p.kind === "baseline").map((p) => [p.baseline, p]));
  const byKey = Object.fromEntries(players.map((p) => [p.key, p]));
  const refs = ["random", "callingStation", "gto"].filter((k) => base[k]).map((k) => ({ v: base[k].overall.score, label: k === "gto" ? "GTO" : k === "callingStation" ? "Calling stn" : "Random" }));
  const partial = (p) => (p.complete ? "" : ` (${p.answered}/${p.total})`);
  const rowOf = (p, extra = {}) => ({ key: p.key, label: p.name + partial(p), short: shortName(p), ...extra });

  const tips = {};
  const charts = [];

  // 1. Score with CI.
  const scoreLo = Math.max(0, Math.floor(Math.min(...dms.map((p) => p.overall.score - p.overall.scoreCI), ...refs.map((r) => r.v)) / 10) * 10);
  charts.push(["ch-score", (el) => rowsChart(el, {
    aria: `GTO score with 95% confidence intervals for ${dms.length} decision models. Best: ${dms[0]?.name} at ${dms[0]?.overall.score.toFixed(1)}.`,
    rows: dms.map((p) => rowOf(p, { tipKind: "score" })),
    x: { lo: scoreLo, hi: 100, fmt: (v) => v },
    refs, labelW: 230,
    marks: (row, x, cy) => {
      const o = byKey[row.key].overall;
      const a = x(Math.max(scoreLo, o.score - o.scoreCI)), b = x(Math.min(100, o.score + o.scoreCI));
      return `<line x1="${a}" x2="${b}" y1="${cy}" y2="${cy}" stroke="var(--s1)" stroke-width="2" stroke-linecap="round" opacity=".55"/>` +
        `<line x1="${a}" x2="${a}" y1="${cy - 4}" y2="${cy + 4}" stroke="var(--s1)" stroke-width="2" opacity=".55"/>` +
        `<line x1="${b}" x2="${b}" y1="${cy - 4}" y2="${cy + 4}" stroke="var(--s1)" stroke-width="2" opacity=".55"/>` +
        dot(x(o.score), cy, "var(--s1)", 5, !byKey[row.key].complete) +
        `<text class="val" x="${b + 8}" y="${cy + 4}">${o.score.toFixed(1)}</text>`;
    },
  })]);
  for (const p of players) {
    const o = p.overall;
    tips[`score:${p.key}`] = `<b>${esc(p.name)}</b>${ttRows([
      ["GTO score", `${o.score.toFixed(1)} ± ${o.scoreCI.toFixed(1)}`],
      ["EV loss", `${fmt.pct(o.lossPot, 2)} pot`],
      o.mixedPot != null && ["Mixed EV loss", `${fmt.pct(o.mixedPot, 2)} pot`],
      ["Best action", fmt.pct(o.best, 0)],
      ["Decisions", `${p.answered}/${p.total}`],
    ])}`;
  }

  // 2. Argmax vs mixed EV loss.
  const lossHi = Math.max(...dms.flatMap((p) => [p.overall.lossPot, p.overall.mixedPot ?? 0])) * 1.08 || 0.1;
  charts.push(["ch-mixed", (el) => rowsChart(el, {
    aria: "EV lost per decision as % of pot, argmax pick vs playing the returned distribution, per decision model.",
    rows: dms.map((p) => rowOf(p)),
    x: { lo: 0, hi: lossHi, fmt: (v) => `${(v * 100).toFixed(v * 100 < 10 ? (lossHi < 0.05 ? 1 : 0) : 0)}%` },
    labelW: 150, right: 18, short: true,
    marks: (row, x, cy) => {
      const o = byKey[row.key].overall;
      const a = x(o.lossPot), b = x(o.mixedPot ?? o.lossPot);
      return `<line x1="${a}" x2="${b}" y1="${cy}" y2="${cy}" stroke="var(--axis)" stroke-width="2"/>` +
        dot(b, cy, "var(--s2)") + dot(a, cy, "var(--s1)");
    },
  })]);

  // 3. Cost vs score scatter.
  const priced = dms.filter((p) => p.cost && p.cost.per1k > 0);
  charts.push(["ch-cost", (el) => {
    if (!priced.length) { el.innerHTML = `<p class="footnote">No cost data yet.</p>`; return; }
    if (!el.clientWidth) return;
    const W = Math.max(280, el.clientWidth), H = Math.round(Math.min(380, Math.max(260, W * 0.68)));
    const m = { l: 40, r: 16, t: 14, b: 34 };
    const xs = priced.map((p) => p.cost.per1k);
    const x0 = 10 ** Math.floor(Math.log10(Math.min(...xs) * 0.8)), x1 = Math.max(...xs) * 1.6;
    const x = logScale(x0, x1, m.l, W - m.r);
    const ys = priced.map((p) => p.overall.score);
    const yLo = Math.max(0, Math.floor((Math.min(...ys, base.random?.overall.score ?? 100) - 5) / 10) * 10);
    const y = linear(yLo, 100, H - m.b, m.t);
    let s = `<svg ${NS} viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-label="Scatter of GTO score against cost per 1,000 decisions for ${priced.length} decision models.">`;
    for (const t of niceTicks(yLo, 100, 5)) s += `<line class="grid" x1="${m.l}" x2="${W - m.r}" y1="${y(t)}" y2="${y(t)}"/><text class="tick-t" x="${m.l - 6}" y="${y(t) + 4}" text-anchor="end">${t}</text>`;
    for (const t of logTicks(x0, x1)) s += `<line class="grid" x1="${x(t)}" x2="${x(t)}" y1="${m.t}" y2="${H - m.b}"/><text class="tick-t" x="${x(t)}" y="${H - m.b + 16}" text-anchor="middle">${fmt.usd(t)}</text>`;
    s += `<text class="tick-t" x="${W - m.r}" y="${H - 4}" text-anchor="end">$ per 1,000 decisions →</text>`;
    for (const r of refs) {
      if (r.v < yLo) continue;
      s += `<line class="ref" x1="${m.l}" x2="${W - m.r}" y1="${y(r.v)}" y2="${y(r.v)}"/><text class="ref-t" x="${W - m.r - 2}" y="${y(r.v) - 4}" text-anchor="end">${esc(r.label)}</text>`;
    }
    // Greedy direct labels: right, left, above, below; skip when nothing fits (tooltip still works).
    const boxes = priced.map((p) => ({ x: x(p.cost.per1k) - 6, y: y(p.overall.score) - 6, w: 12, h: 12 }));
    boxes.push(...refs.map((r) => ({ x: W - m.r - 70, y: y(r.v) - 16, w: 70, h: 14 })));
    const hit = (b) => boxes.some((o) => b.x < o.x + o.w && b.x + b.w > o.x && b.y < o.y + o.h && b.y + b.h > o.y);
    let labels = "";
    for (const p of priced.slice().sort((a, b) => b.overall.score - a.overall.score)) {
      const cx = x(p.cost.per1k), cy = y(p.overall.score), name = shortName(p), w = textWidth(name, 11.5);
      const cands = [[cx + 9, cy + 4, "start"], [cx - 9, cy + 4, "end"], [cx, cy - 10, "middle"], [cx, cy + 18, "middle"], [cx + 7, cy - 8, "start"], [cx - 7, cy - 8, "end"], [cx + 7, cy + 16, "start"], [cx - 7, cy + 16, "end"]];
      for (const [lx, ly, anchor] of cands) {
        const bx = anchor === "start" ? lx : anchor === "end" ? lx - w : lx - w / 2;
        const b = { x: bx, y: ly - 11, w, h: 14 };
        if (b.x < m.l || b.x + b.w > W - 2 || b.y < 0 || b.y + b.h > H - m.b) continue;
        if (hit(b)) continue;
        boxes.push(b);
        labels += `<text class="lab" x="${lx}" y="${ly}" text-anchor="${anchor}" style="font-size:11.5px">${esc(name)}</text>`;
        break;
      }
    }
    for (const p of priced) {
      const cx = x(p.cost.per1k), cy = y(p.overall.score);
      s += `<g>${dot(cx, cy, "var(--s1)", 5, !p.complete)}<circle class="hit" cx="${cx}" cy="${cy}" r="13" tabindex="0" data-tip="cost:${esc(p.key)}" aria-label="${esc(`${p.name}: score ${p.overall.score.toFixed(1)}, ${fmt.usd(p.cost.per1k)} per 1,000 decisions`)}"/></g>`;
    }
    s += labels + `</svg>`;
    el.innerHTML = s;
  }]);
  for (const p of priced) {
    tips[`cost:${p.key}`] = `<b>${esc(p.name)}</b>${ttRows([
      ["GTO score", p.overall.score.toFixed(1)],
      ["Cost / 1k decisions", fmt.usd(p.cost.per1k)],
      ["Input price", p.inputPricePerM != null ? `$${p.inputPricePerM}/M tokens` : "unknown"],
      ["Prompt tokens / decision", fmt.int(p.tokens?.promptPerDecision)],
    ])}`;
  }

  // 4 & 5. Breakdowns (two series each).
  const pair = (id, field, keys, names) => {
    const vals = dms.flatMap((p) => keys.map((k) => p[field][k]?.score).filter((v) => v != null));
    const lo = Math.max(0, Math.floor(Math.min(...vals, 100) / 10) * 10);
    charts.push([id, (el) => rowsChart(el, {
      aria: `GTO score by ${names.join(" and ")} for each decision model.`,
      rows: dms.map((p) => rowOf(p)),
      x: { lo, hi: 100, fmt: (v) => v },
      labelW: 150, right: 18, short: true,
      marks: (row, x, cy) => {
        const p = byKey[row.key];
        const a = p[field][keys[0]], b = p[field][keys[1]];
        let s = "";
        if (a && b) s += `<line x1="${x(a.score)}" x2="${x(b.score)}" y1="${cy}" y2="${cy}" stroke="var(--axis)" stroke-width="2"/>`;
        if (b) s += dot(x(b.score), cy, "var(--s2)");
        if (a) s += dot(x(a.score), cy, "var(--s1)");
        return s;
      },
    })]);
    for (const p of dms) {
      tips[`${id}:${p.key}`] = `<b>${esc(p.name)}</b>${ttRows(keys.map((k, i) => {
        const b = p[field][k];
        return [names[i], b ? `${b.score.toFixed(1)} ± ${b.scoreCI.toFixed(1)} (n=${b.n})` : "–"];
      }))}`;
    }
  };
  pair("ch-street", "byStreet", ["turn", "river"], ["Turn", "River"]);
  pair("ch-type", "byType", ["firstToAct", "facingBet"], ["Check / bet", "Facing a bet"]);

  // 6. Latency.
  const timed = dms.filter((p) => p.latency && p.latency.median > 0).sort((a, b) => a.latency.median - b.latency.median);
  const lats = timed.flatMap((p) => [p.latency.median, p.latency.p90]);
  if (timed.length) {
    const lo = 10 ** Math.floor(Math.log10(Math.min(...lats) * 0.9)), hi = 10 ** Math.ceil(Math.log10(Math.max(...lats) * 1.1));
    charts.push(["ch-latency", (el) => rowsChart(el, {
      aria: `Median and 90th percentile latency per decision. Fastest: ${timed[0].name} at ${fmt.sec(timed[0].latency.median)}.`,
      rows: timed.map((p) => rowOf(p)),
      x: { lo, hi, log: true, fmt: (v) => (v < 1 ? `${Math.round(v * 1000)}ms` : `${v}s`) },
      labelW: 230, right: 70,
      marks: (row, x, cy) => {
        const l = byKey[row.key].latency;
        return `<line x1="${x(l.median)}" x2="${x(l.p90)}" y1="${cy}" y2="${cy}" stroke="var(--s1)" stroke-width="2" stroke-linecap="round" opacity=".55"/>` +
          `<line x1="${x(l.p90)}" x2="${x(l.p90)}" y1="${cy - 4}" y2="${cy + 4}" stroke="var(--s1)" stroke-width="2" opacity=".55"/>` +
          dot(x(l.median), cy, "var(--s1)") + `<text class="val" x="${x(l.p90) + 8}" y="${cy + 4}">${fmt.sec(l.median)}</text>`;
      },
    })]);
  }
  for (const p of timed) {
    tips[`ch-latency:${p.key}`] = `<b>${esc(p.name)}</b>${ttRows([
      ["Median", fmt.sec(p.latency.median)], ["Mean", fmt.sec(p.latency.mean)], ["90th percentile", fmt.sec(p.latency.p90)],
      p.servedBy && ["Served by", p.servedBy],
    ])}`;
  }
  for (const p of dms) {
    const o = p.overall;
    tips[`ch-mixed:${p.key}`] = `<b>${esc(p.name)}</b>${ttRows([
      ["Argmax EV loss", `${fmt.pct(o.lossPot, 2)} ± ${fmt.pct(o.lossPotCI, 2)}`],
      ["Mixed EV loss", o.mixedPot != null ? `${fmt.pct(o.mixedPot, 2)} ± ${fmt.pct(o.mixedPotCI, 2)}` : "–"],
      ["TV distance to GTO", fmt.num(o.tv, 3)],
      ["P(best action)", fmt.pct(o.pBest, 0)],
    ])}`;
  }

  // Legends.
  const legend = { mixed: [["Argmax (the pick)", "s1"], ["Mixed (the distribution)", "s2"]], street: [["Turn", "s1"], ["River", "s2"]], type: [["Check / bet", "s1"], ["Facing a bet", "s2"]] };
  for (const [k, items] of Object.entries(legend)) {
    const el = root.querySelector(`[data-legend="${k}"]`);
    if (el) el.innerHTML = items.map(([t, c]) => `<span><i style="background:var(--${c})"></i>${esc(t)}</span>`).join("");
  }

  const draw = () => {
    for (const [id, fn] of charts) {
      const plot = root.querySelector(`#${id} .plot`);
      if (plot) fn(plot);
    }
  };
  draw();
  // Tooltips keyed per chart: rows carry the player key; resolve with the chart id.
  for (const [id] of charts) {
    const fig = root.querySelector(`#${id}`);
    if (!fig) continue;
    bindTips(fig, (key) => tips[key.includes(":") ? key : `${id === "ch-score" ? "score" : id}:${key}`]);
  }
  let lastW = root.clientWidth;
  new ResizeObserver(() => { if (Math.abs(root.clientWidth - lastW) > 2) { lastW = root.clientWidth; draw(); } }).observe(root);
}

// ── Inline CI whisker for the leaderboard ────────────────
export function whiskerSVG(score, ci, lo, color = "var(--s1)", hollow = false) {
  const W = 96, H = 18, x = linear(lo, 100, 4, W - 4);
  const a = x(Math.max(lo, score - ci)), b = x(Math.min(100, score + ci)), c = x(Math.max(lo, score));
  return `<svg class="whisker" viewBox="0 0 ${W} ${H}" aria-hidden="true">` +
    `<line x1="4" x2="${W - 4}" y1="${H / 2}" y2="${H / 2}" stroke="var(--hair-2)" stroke-width="1"/>` +
    `<line x1="${a}" x2="${b}" y1="${H / 2}" y2="${H / 2}" stroke="${color}" stroke-width="2" stroke-linecap="round" opacity=".6"/>` +
    `<circle cx="${c}" cy="${H / 2}" r="4" fill="${hollow ? "var(--surface)" : color}" stroke="${hollow ? color : "var(--surface)"}" stroke-width="2"/></svg>`;
}

// ── Hero rail: chips stacked at each model's score ───────
export function renderRail(data, el) {
  const dms = data.players.filter((p) => p.kind === "decisionModel").sort((a, b) => a.overall.score - b.overall.score);
  const bases = data.players.filter((p) => p.kind === "baseline" && p.baseline !== "bestEV");
  const all = [...dms.map((p) => p.overall.score), ...bases.map((p) => p.overall.score)];
  const lo = Math.max(0, Math.floor((Math.min(...all) - 3) / 10) * 10);
  const draw = (animate) => {
    const W = Math.max(300, el.clientWidth);
    const narrow = W < 640;
    const chipR = narrow ? 10 : 15, step = chipR * 0.55;
    const x = linear(lo, 100, 12, W - 12);
    // Stack chips that would overlap.
    const stacks = [];
    for (const p of dms) {
      const cx = x(p.overall.score);
      const st = stacks.find((s) => Math.abs(s.x - cx) < chipR * 1.6);
      if (st) st.items.push(p); else stacks.push({ x: cx, items: [p] });
    }
    const maxH = Math.max(1, ...stacks.map((s) => s.items.length));
    const axisY = 78 + (maxH - 1) * step;
    const lanes = narrow ? 3 : 3, laneH = 16;
    const H = axisY + 24 + lanes * laneH + 6;
    let s = `<svg ${NS} viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-label="${esc(`GTO score rail from ${lo} to 100: ${dms.slice().reverse().map((p) => `${p.name} ${p.overall.score.toFixed(1)}`).join(", ")}. Reference bots: ${bases.map((b) => `${b.name} ${b.overall.score.toFixed(1)}`).join(", ")}.`)}">`;
    // Rail.
    s += `<rect x="4" y="${axisY - 3}" width="${W - 8}" height="6" rx="3" fill="rgba(0,0,0,.35)"/>`;
    s += `<rect x="4" y="${axisY - 3}" width="${W - 8}" height="2" rx="1" fill="rgba(255,255,255,.12)"/>`;
    for (const t of niceTicks(lo, 100, narrow ? 5 : 10)) {
      s += `<line x1="${x(t)}" x2="${x(t)}" y1="${axisY + 4}" y2="${axisY + 9}" stroke="rgba(255,255,255,.35)"/>`;
      s += `<text class="tick" x="${x(t)}" y="${axisY + 21}" text-anchor="middle">${t}</text>`;
    }
    // Baseline posts.
    let prevRight = -1e9, lane = 0;
    for (const b of bases.slice().sort((p, q) => p.overall.score - q.overall.score)) {
      const bx = x(b.overall.score);
      const label = b.baseline === "gto" ? "GTO" : b.baseline === "callingStation" ? (narrow ? "Calling stn" : "Calling station") : b.name;
      const text = `${label} · ${b.overall.score.toFixed(1)}`;
      const tw = textWidth(text, 12);
      const anchor = bx > W - tw / 2 - 4 ? "end" : bx < tw / 2 + 4 ? "start" : "middle";
      const left = anchor === "end" ? bx + 6 - tw : anchor === "start" ? bx - 6 : bx - tw / 2;
      lane = left < prevRight + 6 ? Math.min(2, lane + 1) : 0;
      prevRight = left + tw;
      const ty = 10 + lane * 15;
      const tx = anchor === "end" ? bx + 6 : anchor === "start" ? bx - 6 : bx;
      s += `<line x1="${bx}" x2="${bx}" y1="${ty + 8}" y2="${axisY - 4}" stroke="var(--gold)" stroke-width="1.5" opacity=".75"/>`;
      s += `<path d="M${bx - 4} ${ty + 8} l4 -4 l4 4 l-4 4z" fill="var(--gold)"/>`;
      s += `<text class="post-label" x="${tx}" y="${ty}" text-anchor="${anchor}">${esc(text)}</text>`;
      s += `<rect class="hit" x="${bx - 10}" y="0" width="20" height="${axisY}" tabindex="0" data-tip="${esc(b.key)}" aria-label="${esc(`${b.name}: ${b.overall.score.toFixed(1)}`)}"/>`;
    }
    // Chips.
    let k = 0;
    for (const st of stacks) {
      st.items.forEach((p, i) => {
        const cy = axisY - chipR - 3 - i * step;
        const delay = animate ? `style="animation-delay:${(k++ * 70)}ms"` : "";
        s += `<g class="chip" ${delay} tabindex="0" data-tip="${esc(p.key)}" role="img" aria-label="${esc(`${p.name}: ${p.overall.score.toFixed(1)}`)}" opacity="${p.complete ? 1 : 0.8}">` +
          `<use href="#chip" x="${st.x - chipR}" y="${cy - chipR}" width="${chipR * 2}" height="${chipR * 2}"/></g>`;
      });
    }
    // Labels in lanes below the rail with leader lines.
    const placed = Array.from({ length: lanes }, () => -1e9);
    const labelled = dms.slice().sort((a, b) => a.overall.score - b.overall.score);
    const fs = narrow ? 10.5 : 11.5;
    for (const p of labelled) {
      const cx = x(p.overall.score), name = shortName(p);
      const w = textWidth(name, fs) + 10;
      let anchor = "middle", lx = cx;
      if (cx - w / 2 < 4) { anchor = "start"; lx = Math.max(4, cx - 6); }
      if (cx + w / 2 > W - 4) { anchor = "end"; lx = Math.min(W - 4, cx + 6); }
      const left = anchor === "start" ? lx : anchor === "end" ? lx - w : lx - w / 2;
      const lane = placed.findIndex((r) => left > r + 4);
      if (lane < 0) continue;
      placed[lane] = left + w;
      const ly = axisY + 24 + (lane + 1) * laneH - 3;
      s += `<line x1="${cx}" x2="${cx}" y1="${axisY + 4}" y2="${ly - 11}" stroke="rgba(255,255,255,.22)"/>`;
      s += `<text class="chip-label" x="${lx}" y="${ly}" text-anchor="${anchor}" style="font-size:${fs}px">${esc(name)}</text>`;
    }
    s += `</svg>`;
    el.innerHTML = s;
    el.classList.toggle("rail-enter", !!animate && !matchMedia("(prefers-reduced-motion: reduce)").matches);
  };
  draw(true);
  bindTips(el, (key) => {
    const p = data.players.find((q) => q.key === key);
    if (!p) return "";
    const o = p.overall;
    return `<b>${esc(p.name)}</b>${p.kind === "baseline" ? `<div class="tt-row"><span>${esc(p.summary ?? "")}</span></div>` : ""}${ttRows([
      ["GTO score", `${o.score.toFixed(1)} ± ${o.scoreCI.toFixed(1)}`],
      ["EV loss", `${fmt.pct(o.lossPot, 2)} pot`],
      !p.complete && ["Answered", `${p.answered}/${p.total}`],
    ])}`;
  });
  let lastW = el.clientWidth;
  new ResizeObserver(() => { if (Math.abs(el.clientWidth - lastW) > 2) { lastW = el.clientWidth; draw(false); } }).observe(el);
}
