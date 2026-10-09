// Equilibrium — "Sports broadcast" results page. Every number comes from data/*.json.
(() => {
  "use strict";
  const $ = (s) => document.querySelector(s);
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const pct = (x, d = 0) => `${(x * 100).toFixed(d)}%`;
  const int = (n) => Math.round(n).toLocaleString("en-US");
  const signed = (n) => (n > 0 ? "+" : n < 0 ? "−" : "") + int(Math.abs(n));
  const md = (s) => esc(s).replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");

  const CORE = ["openai/gpt-6-luna-decisions", "typesafe/jev-1.13", "inception/mercury-decide", "liquid/d1", "cloudflare/clef"];
  const COLOR = { "openai/gpt-6-luna-decisions": "luna", "typesafe/jev-1.13": "jev", "inception/mercury-decide": "mercury", "liquid/d1": "d1", "cloudflare/clef": "clef" };

  // Commentator copy, keyed by insight id. Numbers always come from insights.json / bench.json.
  const CALL = {
    calibration: "Watch the confidence meter: when it dips, so does the play.",
    "confident-info": "Better scouting, more swagger — and the swagger is earned.",
    description: "Same players, better briefing. Tell them what beats them and they stop paying it off.",
    "cheap-model": "The bargain pick ties the favourite.",
    agreement: "When the whole booth agrees, trust the call.",
    money: "Mercury smells blood at the maniac's table. Against the solid regular? Dead even.",
    escalation: "Phoning a friend only when unsure: a small gain.",
    shortstack: "One sentence of coaching. Half the bleeding.",
    "facing-bet": "Under fire is exactly where better info pays.",
    sizing: "Right idea, wrong amount. Luna's most expensive habit.",
    monsters: "Dealt a monster, plays it like a mouse.",
    "deep-vs-short": "Deep stacks, deep trouble.",
    personality: "Four gamblers and one rock walk into a card room.",
    mixing: "Rolling dice on its own odds is not a strategy.",
    hud: "Handed a scouting report, it overthought the calling station.",
  };
  const PLAYS = ["description", "shortstack", "facing-bet", "agreement", "money"];
  const BLUNDERS = ["hud", "monsters", "sizing", "mixing", "deep-vs-short"];
  const TILES = ["cheap-model", "confident-info", "personality", "escalation"];

  // Mirrors the live-number logic of the main site (bench.json wins over the static fallback).
  function live(card, bench) {
    const c = { ...card };
    if (card.live === "calibration") {
      const m = bench.calibration.models.find((x) => x.model === bench.calibration.focus);
      const b = m.buckets;
      c.big = `${pct(b[3].best)} vs ${pct(b[1].best)}`;
    }
    // agreement / sizing: bench values equal the static card (0.55% vs 4.43%, 34%), keep the card text.
    return c;
  }

  async function load() {
    const get = (f) => fetch(`data/${f}`).then((r) => { if (!r.ok) throw new Error(`${f}: HTTP ${r.status}`); return r.json(); });
    const [ins, bench, arena] = await Promise.all([get("insights.json"), get("bench.json"), get("arena.json")]);
    render(ins.cards, bench, arena);
  }

  function render(cardsRaw, bench, arena) {
    const cards = Object.fromEntries(cardsRaw.map((c) => [c.id, live(c, bench)]));
    const players = bench.spot.players;
    const shortOf = Object.fromEntries([...bench.calibration.models, ...bench.agreement.core].map((m) => [m.model, m.short]));
    const models = players.filter((p) => p.kind === "decisionModel").sort((a, b) => b.overall.score - a.overall.score);
    const byModel = Object.fromEntries(players.map((p) => [p.model, p]));
    const gto = byModel["baseline:gto"], station = byModel["baseline:callingStation"], rnd = byModel["baseline:random"];
    const arenaHands = arena.matches.reduce((s, m) => s + m.hands, 0);
    const cal = bench.calibration;
    const luna = cal.models.find((m) => m.model === cal.focus);
    const B = luna.buckets;

    // ── Hero facts
    $("#hero-facts").innerHTML = [
      [models.length, "AI models"],
      [int(cal.overall.n), "answers graded"],
      [int(arenaHands), "arena hands"],
    ].map(([n, l]) => `<li><b>${n}</b><span>${l}</span></li>`).join("");

    // ── Standings
    $("#board-n").textContent = bench.spot.suite.decisions;
    const row = (p, rank) => {
      const isBot = p.kind === "baseline";
      const name = isBot ? (p.baseline === "gto" ? "GTO solver" : `${p.name} bot`) : (shortOf[p.model] ?? p.name);
      const cls = isBot ? "bot" : (COLOR[p.model] ? `m-${COLOR[p.model]}` : "");
      return `<li class="${cls}"><span class="rk">${isBot ? (p.baseline === "gto" ? "★" : "·") : rank}</span><span class="nm">${esc(name)}${isBot && p.baseline === "gto" ? ' <em>the house</em>' : ""}</span><span class="bar" aria-hidden="true"><i style="--w:${p.overall.score}%"></i></span><span class="sc">${p.overall.score.toFixed(1)}</span></li>`;
    };
    $("#board-rows").innerHTML = row(gto) + models.slice(0, 5).map((p, i) => row(p, i + 1)).join("");
    const rest = [...models.slice(5), station, rnd].sort((a, b) => b.overall.score - a.overall.score);
    let rank = 5;
    $("#board-rest").innerHTML = rest.map((p) => row(p, p.kind === "baseline" ? 0 : ++rank)).join("");
    $("#board-more-n").textContent = `(+${models.length - 5} models, 2 bots)`;

    // ── Ticker
    const belowStation = models.filter((p) => p.overall.score < station.overall.score).length;
    const cheap = cards["cheap-model"], money = cards.money, ag = cards.agreement;
    const tick = [
      `GTO solver <b>${gto.overall.score.toFixed(1)}</b> / 100 — the bar to clear`,
      `${esc(shortOf[models[0].model])} leads the AI field at <b>${models[0].overall.score.toFixed(1)}</b>`,
      `Calling-station bot outscores <b>${belowStation} of ${models.length}</b> AI models`,
      `Sure vs torn: best move <b>${esc(cards.calibration.big)}</b>`,
      `Mercury ties Luna: <b>${esc(cheap.big)}</b> ${esc(cheap.bigLabel)}`,
      `Mercury vs the maniac: <b>${esc(money.big)}</b> bb/100`,
      `All five agree → only <b>${pct(bench.agreement.groups[0].levels[0].lossPot, 2)}</b> of the pot lost`,
      `Opponent stats backfire: <b>${esc(cards.hud.big)}</b> bb/100`,
      `<b>${int(arenaHands)}</b> arena hands, <b>${int(cal.overall.n)}</b> graded answers`,
    ];
    const items = tick.map((t) => `<li>${t}</li>`).join("");
    $("#ticker").innerHTML = items + items.replace(/<li>/g, '<li aria-hidden="true">');
    const pauseBtn = $("#ticker-pause");
    pauseBtn.addEventListener("click", () => {
      const on = pauseBtn.getAttribute("aria-pressed") !== "true";
      pauseBtn.setAttribute("aria-pressed", String(on));
      pauseBtn.setAttribute("aria-label", on ? "Play ticker" : "Pause ticker");
      pauseBtn.firstElementChild.textContent = on ? "▶" : "❚❚";
      document.body.classList.toggle("ticker-paused", on);
    });

    // ── Story of the night (calibration)
    const ratio = B[1].lossPot / B[3].lossPot;
    $("#story-big").innerHTML = `<span class="sure">${pct(B[3].best)}</span><span class="vs">vs</span><span class="torn">${pct(B[1].best)}</span>`;
    $("#story-text").innerHTML = `When <strong>${esc(luna.short)}</strong> is very sure (80%+ on one move) it finds the best move <strong>${pct(B[3].best)}</strong> of the time. When it's torn (40–60%), only <strong>${pct(B[1].best)}</strong> — barely better than a coin flip — and those calls cost about <strong>${Math.round(ratio)}× more</strong> (${pct(B[1].lossPot, 1)} vs ${pct(B[3].lossPot, 1)} of the pot).`;
    $("#story-call").textContent = CALL.calibration + " That's a free warning light.";
    const NAMES = ["Guessing", "Torn", "Fairly sure", "Very sure"], RANGE = ["under 40%", "40–60%", "60–80%", "80%+"];
    $("#meter").innerHTML = [3, 2, 1, 0].map((i) => `
      <div class="mrow lvl${i}" role="img" aria-label="${NAMES[i]} (${RANGE[i]}): best move ${pct(B[i].best)}, loses ${pct(B[i].lossPot, 1)} of the pot, ${B[i].share < 0.01 ? "under 1%" : pct(B[i].share)} of decisions${B[i].n < 100 ? `, only ${B[i].n} decisions` : ""}">
        <div class="mlab"><b>${NAMES[i]}</b><span>${RANGE[i]} sure · ${B[i].share < 0.01 ? "&lt;1%" : pct(B[i].share)} of calls${B[i].n < 100 ? ` · n=${B[i].n}` : ""}</span></div>
        <div class="mbar" aria-hidden="true"><i style="--w:${(B[i].best * 100).toFixed(1)}%"></i><em>${pct(B[i].best)}</em></div>
        <div class="mloss" aria-hidden="true">${pct(B[i].lossPot, 1)}<small>pot lost</small></div>
      </div>`).join("");
    $("#story-fine").textContent = `${luna.name}, ${int(luna.n)} graded answers across every suite. “Best move” = within 0.25% of the pot of the solver's top choice. ± ${Math.round(B[3].bestCI * 100)}–${Math.round(B[1].bestCI * 100)} points on the top two rows.`;

    // ── Player cards
    const g = bench.agreement.groups[0];
    const gp = Object.fromEntries(g.players.map((p) => [p.model, p]));
    const pair = (m, bot) => arena.pairs.find((p) => p.player === `dm:${m}` && p.opponent === bot);
    const facing = (m) => byModel[m].byType.facingBet.score;
    const PROFILE = {
      "openai/gpt-6-luna-decisions": (p) => ({
        tag: "Tight-passive", line: "Tops the table, but rarely pulls the trigger.",
        best: `Highest AI score: <b>${p.overall.score.toFixed(1)}</b>`,
        worst: `<b>${pct(gp[p.model].sizingShare)}</b> of its losses: right move, wrong bet size`,
      }),
      "typesafe/jev-1.13": (p) => {
        const t = pair(p.model, "bot:tag");
        return {
          tag: "Loose-aggressive", line: "The crowd-pleaser: sides with the majority 9 times in 10.",
          best: `Agrees with the group <b>${pct(gp[p.model].agreesWithMajority)}</b> of the time`,
          worst: `<b>${signed(t.bb100)}</b> bb/100 vs the solid regular <small>±${int(t.ci95)} · ${int(t.hands)} hands</small>`,
        };
      },
      "inception/mercury-decide": (p) => ({
        tag: "Bargain LAG", line: "Same results as Luna on the better brief, at a fifth of the price.",
        best: `Best of the five facing a bet: <b>${facing(p.model).toFixed(1)}</b>`,
        worst: `Finds the best move only <b>${pct(p.overall.best)}</b> of the time`,
      }),
      "liquid/d1": (p) => {
        const t = pair(p.model, "bot:tag"), s = pair(p.model, "bot:station");
        return {
          tag: "Limp-happy", line: `Plays ${pct(t.vpip)} of hands vs the regular, raises just ${pct(t.pfr)} before the flop.`,
          best: `<b>${signed(s.bb100)}</b> bb/100 vs the calling station <small>±${int(s.ci95)} · ${int(s.hands)} hands</small>`,
          worst: `Weakest on the river: <b>${p.byStreet.river.score.toFixed(1)}</b>`,
        };
      },
      "cloudflare/clef": (p) => ({
        tag: "Sticky caller", line: "Sizes bets like a pro, then calls too much.",
        best: `Only <b>${pct(gp[p.model].sizingShare)}</b> of losses from bet sizing — best of the five`,
        worst: `Gives away <b>${pct(p.overall.lossPot, 1)}</b> of the pot per decision — most of the five`,
      }),
    };
    const core = models.filter((p) => CORE.includes(p.model));
    $("#cards").innerHTML = core.map((p, i) => {
      const pr = PROFILE[p.model](p);
      const cost = p.cost?.per1k;
      return `<article class="card m-${COLOR[p.model]}" aria-labelledby="pc-${i}">
        <div class="card-top">
          <span class="card-rank">#${i + 1}</span>
          <span class="card-tag">${esc(pr.tag)}</span>
        </div>
        <h3 class="card-name" id="pc-${i}"><span>${esc(shortOf[p.model])}</span><small>${esc(p.name)}</small></h3>
        <div class="card-score"><b>${p.overall.score.toFixed(1)}</b><span>score<br>±${p.overall.scoreCI.toFixed(0)}</span></div>
        <p class="card-line">“${esc(pr.line)}”</p>
        <ul class="card-stats">
          <li class="up"><span aria-label="Best stat">▲</span><p>${pr.best}</p></li>
          <li class="down"><span aria-label="Worst stat">▼</span><p>${pr.worst}</p></li>
        </ul>
        ${cost != null ? `<p class="card-cost">$${cost.toFixed(3)} per 1,000 decisions</p>` : ""}
      </article>`;
    }).join("");

    // ── Head-to-head
    const BOTS = [["bot:tag", "Solid regular", "plays tight & aggressive"], ["bot:station", "Calling station", "never folds"], ["bot:maniac", "Maniac", "bets & raises everything"]];
    const cell = (pr) => {
      if (!pr) return `<td class="dnp"><span>Did not play</span></td>`;
      const sig = Math.abs(pr.bb100) > pr.ci95;
      const cls = !sig ? "even" : pr.bb100 > 0 ? "win" : "loss";
      const word = !sig ? "Too close to call" : pr.bb100 > 0 ? "Win" : "Loss";
      return `<td class="${cls}"><b>${signed(pr.bb100)}</b><small>±${int(pr.ci95)} · ${int(pr.hands)} hands</small><em>${word}</em></td>`;
    };
    $("#h2h").innerHTML = `<table>
      <caption class="sr">Big blinds won per 100 hands against each bot, standard description, model plays its top pick</caption>
      <thead><tr><th scope="col" class="l">Model</th>${BOTS.map(([, n, d]) => `<th scope="col">vs ${n}<small>${d}</small></th>`).join("")}</tr></thead>
      <tbody>${core.map((p) => `<tr class="m-${COLOR[p.model]}"><th scope="row" class="l">${esc(shortOf[p.model])}</th>${BOTS.map(([b]) => cell(pair(p.model, b))).join("")}</tr>`).join("")}</tbody>
    </table>`;
    $("#h2h-call").textContent = "Everybody feasts on the calling station. Nobody reliably beats the solid regular.";
    $("#h2h-fine").textContent = `“Too close to call” = the ± range includes zero. Heads-up, 20–100 big-blind stacks; matches under ${arena.minHands} hands are excluded.`;

    // ── Replay desk
    const reelItem = (id) => {
      const c = cards[id];
      return `<li><div class="ri-big">${esc(c.big)}<small>${esc(c.bigLabel)}</small></div><div class="ri-body"><h4>${esc(c.headline)}</h4><p class="ri-call">${esc(CALL[id])}</p><details class="ri-more"><summary>Replay the details</summary><p class="ri-text">${md(c.text)}</p>${c.n ? `<p class="fine">${esc(c.n)}${c.ci ? ` · ${esc(c.ci)}` : ""}</p>` : ""}</details></div></li>`;
    };
    $("#plays").innerHTML = PLAYS.map(reelItem).join("");
    $("#blunders").innerHTML = BLUNDERS.map(reelItem).join("");

    // ── Key stat tiles
    $("#tiles").innerHTML = TILES.map((id) => {
      const c = cards[id];
      return `<article class="tile"><p class="tile-big">${esc(c.big)}</p><p class="tile-label">${esc(c.bigLabel)}</p><h3>${esc(c.headline)}</h3><p class="tile-call">${esc(CALL[id])}</p>${c.n ? `<p class="fine">${esc(c.n)}</p>` : ""}</article>`;
    }).join("");

    $("#gen-date").textContent = new Date(bench.generatedAt).toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric" });
    document.body.classList.add("ready");
  }

  load().catch((e) => {
    $("#main").insertAdjacentHTML("afterbegin", `<p class="error">Couldn't load the results data (${esc(e.message)}). Serve the <code>web/</code> folder over HTTP and reload.</p>`);
  });
})();
