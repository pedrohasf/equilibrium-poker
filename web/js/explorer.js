// Spot explorer: filterable list of decisions + a table view of the selected spot.
// Works for any exported suite (spot suite, full-hand and preflop suites); `load(data, key)` swaps the suite.
import { esc, fmt, cardHTML, cardBackHTML, miniCardHTML, cardsText, actionColors, bindTips, ttRows, lossStatus, statusHTML } from "./util.js";

const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);

export function createExplorer(root, { onSelect } = {}) {
  let data = null, players = [], decisions = [], suite = null, suiteKey = "spots";
  let tol = 0.0025, blunderAt = 0.25, scenarios = {}, info = new Map();

  function setData(d, key) {
    data = d; suiteKey = key;
    ({ players, decisions, suite } = d);
    tol = suite.scoring?.bestTolerancePot ?? 0.0025;
    blunderAt = suite.scoring?.blunderThresholdPot ?? 0.25;
    scenarios = Object.fromEntries((suite.scenarios ?? []).map((s) => [s.id, s]));
    const dmIdx = players.map((p, i) => (p.kind !== "baseline" ? i : -1)).filter((i) => i >= 0);
    info = new Map(decisions.map((d) => {
      const ans = dmIdx.map((i) => d.answers[i]).filter(Boolean);
      const picks = new Set(ans.filter((a) => a[0] >= 0).map((a) => a[0]));
      return [d.id, {
        answered: ans.length,
        split: picks.size > 1,
        blunder: ans.some((a) => a[0] < 0 || a[1] > blunderAt),
        nBest: ans.filter((a) => a[0] >= 0 && a[1] <= tol).length,
      }];
    }));
    // Street filter from the streets present in this suite.
    const streets = ["preflop", "flop", "turn", "river"].filter((st) => decisions.some((d) => d.street === st));
    const seg = root.querySelector('.seg[data-filter="street"]');
    seg.innerHTML = [["all", "All streets"], ...streets.map((st) => [st, cap(st)])].map(([v, t], i) =>
      `<button type="button" role="radio" aria-checked="${i === 0}" data-v="${v}">${t}</button>`).join("");
    seg.hidden = streets.length < 2;
    filters.street = "all";
    current = null;
  }

  const filters = { street: "all", type: "all", split: false, blunder: false };
  let list = [];
  let current = null;
  let revealed = false;

  const listEl = root.querySelector("#ex-list");
  const spotEl = root.querySelector("#ex-spot");
  const countEl = root.querySelector("#ex-count");

  function apply() {
    list = decisions.filter((d) => {
      const i = info.get(d.id);
      return (filters.street === "all" || d.street === filters.street)
        && (filters.type === "all" || d.type === filters.type)
        && (!filters.split || i.split)
        && (!filters.blunder || i.blunder);
    });
    countEl.textContent = `${list.length} of ${decisions.length} decisions`;
    if (!list.length) {
      listEl.innerHTML = `<li class="empty">No spot matches these filters. Clear a filter to see more.</li>`;
      return;
    }
    listEl.innerHTML = list.map((d) => {
      const i = info.get(d.id);
      const hero = d.positions[d.heroSeat];
      return `<li><button type="button" data-id="${d.id}" aria-current="${d.id === current}" aria-label="${esc(`${d.id}, ${d.street}, ${hero} ${d.type === "facingBet" ? "facing a bet" : "to act"}, ${i.nBest} of ${i.answered} models found the best action`)}">` +
        `<span class="id">${d.id}</span><span class="mini">${d.hero.map(miniCardHTML).join("")}</span>` +
        `<span class="meta"><span>${d.hand ? `${esc(d.hand)} · ` : ""}${cap(d.street)} · ${esc(hero)} ${d.type === "facingBet" ? "faces bet" : "to act"}</span>` +
        `<span class="agree" title="Models that found a best-EV action">${i.nBest}/${i.answered}</span></span></button></li>`;
    }).join("");
  }

  function select(id, { push = true, focusList = false } = {}) {
    const d = decisions.find((x) => x.id === id);
    if (!d) return;
    if (current !== id) revealed = false;
    current = id;
    for (const b of listEl.querySelectorAll("button[data-id]")) b.setAttribute("aria-current", String(b.dataset.id === id));
    const btn = listEl.querySelector(`button[data-id="${id}"]`);
    if (btn) {
      const lr = listEl.getBoundingClientRect(), br = btn.getBoundingClientRect();
      if (br.top < lr.top || br.bottom > lr.bottom) listEl.scrollTop += br.top - lr.top - lr.height / 2 + br.height / 2;
      if (focusList) btn.focus({ preventScroll: true });
    }
    renderSpot(d);
    const h = suiteKey === "spots" ? `#${id}` : `#${suiteKey}/${id}`;
    if (push && location.hash !== h) history.replaceState(null, "", h);
    onSelect?.(suiteKey, id);
  }

  function step(delta) {
    if (!list.length) return;
    const i = list.findIndex((d) => d.id === current);
    const next = list[Math.max(0, Math.min(list.length - 1, (i < 0 ? 0 : i + delta)))];
    select(next.id, { focusList: document.activeElement?.closest?.("#ex-list") != null });
  }

  function renderSpot(d) {
    const hero = d.heroSeat, vil = 1 - hero;
    const colors = actionColors(d.actions);
    const sc = scenarios[d.scenario];
    const best = d.best;
    const i = info.get(d.id);
    const lastStreet = d.history[d.history.length - 1];

    // Table.
    const seat = (s, isHero) => {
      const cards = isHero ? d.hero.map((c) => cardHTML(c, "lg")).join("")
        : revealed ? d.villain.map((c) => cardHTML(c)).join("") : cardBackHTML() + cardBackHTML();
      const who = `<div class="who">${esc(d.positions[s])}${isHero ? " · hero" : ""}<small>${fmt.bb(d.stacks[s])} bb behind${d.street === "preflop" ? "" : ` · ${s === 1 ? "in position" : "out of position"}`}</small>` +
        (isHero ? "" : `<button type="button" class="reveal" data-act="reveal">${revealed ? "hide hand" : "reveal hand"}</button>`) + `</div>`;
      return `<div class="seat ${isHero ? "is-hero" : "is-villain"}">${isHero ? cards + who : who + cards}</div>`;
    };
    const newCards = new Set(lastStreet?.cards ?? []);
    const board = d.board.map((c) => cardHTML(c, newCards.has(c) && d.board.length > 3 ? "new" : "")).join("");
    const table = `<div class="table-felt">${seat(vil, false)}<div class="board-zone"><div class="board" aria-label="Board">${board}</div>` +
      `<div class="pot">pot <b>${fmt.bb(d.pot)} bb</b>${d.toCall > 0 ? ` · to call <b>${fmt.bb(d.toCall)} bb</b>` : ""}</div>` +
      `<div class="facing">${d.toCall > 0 ? `${esc(d.positions[vil])} bet — ${esc(d.positions[hero])} to act` : `${esc(d.positions[hero])} to act`}</div></div>${seat(hero, true)}</div>`;

    const hist = `<ol class="history" aria-label="Action history">${d.history.map((st) => {
      const acts = st.acts.length ? st.acts.map((a) => `<span class="${a.seat === hero ? "hero-act" : ""}">${esc(a.t)}</span>`).join(", ") : `<span>${esc(d.positions[hero])} to act</span>`;
      const syn = st.acts.some((a) => a.syn) ? ` <span class="syn" title="Synthetic line that sets pot and stacks (not solved)">set-up</span>` : "";
      return `<li><span class="st">${st.street}</span><span class="cards">${st.cards.map(miniCardHTML).join("")}</span><span class="acts">${acts}${syn} <span class="syn">· pot ${fmt.bb(st.pot)}</span></span></li>`;
    }).join("")}</ol>`;

    // Solver panel.
    const gtoBar = `<div class="stack big" role="img" aria-label="${esc(`GTO strategy: ${d.actions.map((a, k) => `${a.l} ${Math.round(d.gto[k] * 100)}%`).join(", ")}`)}">` +
      d.actions.map((a, k) => d.gto[k] > 0.004 ? `<i style="flex:${d.gto[k]};background:${colors[k]}" data-tip="gto:${k}"></i>` : "").join("") + `</div>`;
    const bestEV = Math.max(...d.ev);
    const evRows = d.actions.map((a, k) => {
      const loss = (bestEV - d.ev[k]) / d.pot;
      return `<tr class="${k === best ? "best" : ""}"><td class="l"><span class="sw" style="background:${colors[k]}"></span>${esc(a.l)}${k === best ? `<span class="star">★ best EV</span>` : ""}</td>` +
        `<td>${fmt.pct(d.gto[k], 0)}</td><td>${d.ev[k] >= 0 ? "+" : ""}${d.ev[k].toFixed(2)}</td><td>${loss < 1e-4 ? "—" : `−${(loss * 100).toFixed(1)}%`}</td></tr>`;
    }).join("");
    const solver = `<section class="panel"><h4>Solver strategy for ${esc(cardsText(d.hero))}</h4>${gtoBar}` +
      `<table class="ev-table"><thead><tr><th class="l" style="text-align:left">Action</th><th>GTO</th><th>EV (bb)</th><th>Loss</th></tr></thead><tbody>${evRows}</tbody></table>` +
      `<p class="footnote" style="margin:10px 0 0">Equity vs. range ${fmt.pct(d.equity, 0)} · solved to ${d.expl.toFixed(2)}% pot exploitability · EVs relative to this node.</p></section>`;

    // Answers.
    const rows = players.map((p, k) => ({ p, a: d.answers[k] })).filter((r) => r.a && r.p.baseline !== "bestEV")
      .sort((x, y) => ((x.p.kind === "baseline") - (y.p.kind === "baseline")) || ((x.a[0] < 0) - (y.a[0] < 0)) || x.a[1] - y.a[1] || (x.a[4] ?? 1) - (y.a[4] ?? 1));
    const ansHTML = rows.map(({ p, a }) => {
      const [choice, lossPot, probs, conf] = a;
      const valid = choice >= 0;
      const st = lossStatus(lossPot, valid, tol, blunderAt);
      const pv = probs ?? (valid ? d.actions.map((_, k) => (k === choice ? 1 : 0)) : null);
      const bar = pv ? `<div class="stack" role="img" aria-label="${esc(`${p.name} probabilities: ${d.actions.map((x, k) => `${x.s} ${Math.round(pv[k] * 100)}%`).join(", ")}`)}">` +
        d.actions.map((_, k) => pv[k] > 0.004 ? `<i style="flex:${pv[k]};background:${colors[k]}" data-tip="p:${p.key}:${k}"></i>` : "").join("") + `</div>`
        : `<div class="stack" aria-label="No answer"></div>`;
      const pick = valid ? d.actions[choice].s : "no valid answer";
      return `<div class="ans ${p.kind === "baseline" ? "baseline" : ""}" data-tip="a:${p.key}"><span class="nm" title="${esc(p.model)}">${esc(p.name)}</span>${bar}` +
        `<span class="res"><span class="lbl">${esc(pick)}</span>${statusHTML(st)}</span></div>`;
    }).join("");
    const answers = `<section class="panel"><h4>What the players chose · ${i.nBest} of ${i.answered} models found a best-EV action</h4><div class="answers">${ansHTML || `<p class="footnote">No answers for this spot yet.</p>`}</div>` +
      `<p class="footnote" style="margin:10px 0 0">Bars show each model's returned probabilities over the actions; the label is its pick. Hover for confidence and latency. Reference bots in gold${players.some((p) => p.borrowedFrom) ? " (borrowed from the parent suite)" : ""}.</p></section>`;

    const idx = list.findIndex((x) => x.id === d.id);
    spotEl.innerHTML = `<header class="spot-head"><h3>${d.id}</h3><span class="sub">${cap(d.street)} · ${esc(sc?.name ?? d.scenario)}${d.hand ? ` · hand ${esc(d.hand)}` : ""} · ${esc(d.preflop)}</span>` +
      `<span class="nav"><button type="button" class="btn" data-act="prev" ${idx <= 0 ? "disabled" : ""} aria-label="Previous spot">← Prev</button><button type="button" class="btn" data-act="next" ${idx < 0 || idx >= list.length - 1 ? "disabled" : ""} aria-label="Next spot">Next →</button></span></header>` +
      `<div class="spot-grid"><div>${table}${hist}</div><div>${solver}${answers}</div></div>`;
    spotEl._d = d;
  }

  // Events.
  listEl.addEventListener("click", (e) => {
    const b = e.target.closest("button[data-id]");
    if (b) select(b.dataset.id);
  });
  spotEl.addEventListener("click", (e) => {
    const act = e.target.closest("[data-act]")?.dataset.act;
    if (act === "prev") step(-1);
    if (act === "next") step(1);
    if (act === "reveal") { revealed = !revealed; renderSpot(spotEl._d); spotEl.querySelector('[data-act="reveal"]')?.focus(); }
  });
  for (const seg of root.querySelectorAll(".seg")) {
    seg.addEventListener("click", (e) => {
      const b = e.target.closest("button");
      if (!b) return;
      for (const x of seg.querySelectorAll("button")) x.setAttribute("aria-checked", String(x === b));
      filters[seg.dataset.filter] = b.dataset.v;
      refresh();
    });
    seg.addEventListener("keydown", (e) => {
      if (!["ArrowLeft", "ArrowRight"].includes(e.key)) return;
      const bs = [...seg.querySelectorAll("button")];
      const i = bs.findIndex((x) => x.getAttribute("aria-checked") === "true");
      const n = bs[(i + (e.key === "ArrowRight" ? 1 : bs.length - 1)) % bs.length];
      n.focus(); n.click(); e.preventDefault();
    });
  }
  for (const cb of root.querySelectorAll('input[type="checkbox"][data-filter]')) {
    cb.addEventListener("change", () => { filters[cb.dataset.filter] = cb.checked; refresh(); });
  }
  document.addEventListener("keydown", (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey || /input|textarea|select/i.test(e.target.tagName)) return;
    if (!data || !root.offsetParent) return;
    const r = root.getBoundingClientRect();
    if (r.bottom < 0 || r.top > innerHeight) return;
    if (e.key === "j" || e.key === "J") { step(1); e.preventDefault(); }
    if (e.key === "k" || e.key === "K") { step(-1); e.preventDefault(); }
  });
  bindTips(root, (key) => {
    const d = spotEl._d;
    if (!d || !data) return "";
    const [kind, a, b] = key.split(":");
    if (kind === "gto") return `<b>${esc(d.actions[a].l)}</b>${ttRows([["GTO frequency", fmt.pct(d.gto[a], 1)], ["EV", `${d.ev[a].toFixed(2)} bb`]])}`;
    if (kind === "p") {
      const k = players.findIndex((p) => p.key === a);
      const ans = d.answers[k];
      return `<b>${esc(players[k].name)}</b>${ttRows([[d.actions[b].l, fmt.pct(ans?.[2]?.[b] ?? (ans?.[0] == b ? 1 : 0), 1)], ["GTO", fmt.pct(d.gto[b], 1)]])}`;
    }
    if (kind === "a") {
      const k = players.findIndex((p) => p.key === a);
      const ans = d.answers[k];
      if (!ans) return "";
      return `<b>${esc(players[k].name)}</b>${ttRows([
        ["Pick", ans[0] >= 0 ? d.actions[ans[0]].l : "invalid"],
        ["EV loss (pick)", `${fmt.pct(ans[1], 2)} pot`],
        ans[4] != null && ["EV loss (mixed)", `${fmt.pct(ans[4], 2)} pot`],
        ans[3] != null && ["Confidence", fmt.pct(ans[3], 0)],
        ans[5] != null && ["Latency", fmt.sec(ans[5])],
      ])}`;
    }
    return "";
  });

  function refresh() {
    apply();
    if (list.length && !list.some((d) => d.id === current)) select(list[0].id, { push: false });
    else if (current) select(current, { push: false });
  }

  return {
    load(d, key) { setData(d, key); apply(); },
    open(id) {
      if (!data) return;
      const target = decisions.some((d) => d.id === id) ? id : list[0]?.id;
      if (target) select(target, { push: false });
    },
    get key() { return suiteKey; },
    get data() { return data; },
  };
}
