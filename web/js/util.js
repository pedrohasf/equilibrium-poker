// Shared helpers: formatting, cards, action colours, tooltip.

export const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

export const fmt = {
  /** Fraction → "1.06%" */
  pct(x, d = 1) { return x == null || !isFinite(x) ? "–" : `${(x * 100).toFixed(d)}%`; },
  num(x, d = 1) { return x == null || !isFinite(x) ? "–" : x.toFixed(d); },
  int(x) { return x == null ? "–" : Math.round(x).toLocaleString("en-US"); },
  usd(x) {
    if (x == null || !isFinite(x)) return "–";
    if (x === 0) return "$0";
    if (x < 0.01) return `$${x.toFixed(4)}`;
    if (x < 1) return `$${x.toFixed(3)}`;
    return `$${x.toFixed(2)}`;
  },
  sec(x) { return x == null || !isFinite(x) ? "–" : x < 1 ? `${Math.round(x * 1000)} ms` : `${x.toFixed(x < 10 ? 2 : 1)} s`; },
  bb(x) { return Math.abs(x - Math.round(x)) < 0.05 ? String(Math.round(x)) : Math.abs(x) < 1 ? x.toFixed(2) : x.toFixed(1); },
  date(iso) {
    const d = new Date(iso);
    return isNaN(d) ? iso : d.toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" });
  },
};

// ── Cards ──────────────────────────────────────────────────
const SUIT = { s: "♠", h: "♥", d: "♦", c: "♣" };
const SUIT_NAME = { s: "spades", h: "hearts", d: "diamonds", c: "clubs" };
const RANK_NAME = { A: "Ace", K: "King", Q: "Queen", J: "Jack", T: "Ten", 9: "Nine", 8: "Eight", 7: "Seven", 6: "Six", 5: "Five", 4: "Four", 3: "Three", 2: "Two" };

export function cardParts(c) {
  const r = c[0], s = c[1]?.toLowerCase();
  return { r: r === "T" ? "10" : r, s, glyph: SUIT[s] ?? "?", name: `${RANK_NAME[r] ?? r} of ${SUIT_NAME[s] ?? s}` };
}

export function cardHTML(c, cls = "") {
  const p = cardParts(c);
  return `<span class="card ${p.s} ${cls}" role="img" aria-label="${p.name}"><span class="r">${p.r}</span><span class="s" aria-hidden="true">${p.glyph}</span></span>`;
}
export function cardBackHTML(cls = "") { return `<span class="card back ${cls}" role="img" aria-label="Face-down card"></span>`; }
export function miniCardHTML(c) {
  const p = cardParts(c);
  return `<span class="mc ${p.s}" aria-label="${p.name}">${p.r}${p.glyph}</span>`;
}
export function cardsText(cards) { return cards.map((c) => { const p = cardParts(c); return p.r + p.glyph; }).join(" "); }

// ── Actions ───────────────────────────────────────────────
/** CSS colour (var) for each action of a decision, mirroring the app's action palette. */
export function actionColors(actions) {
  const aggr = actions.map((a, i) => (a.k === "bet" || a.k === "raise" ? i : -1)).filter((i) => i >= 0);
  return actions.map((a, i) => {
    switch (a.k) {
      case "fold": return "var(--a-fold)";
      case "check": case "call": return "var(--a-pass)";
      case "allin": return "var(--a-allin)";
      default: {
        if (aggr.length <= 1) return a.k === "raise" ? "var(--a-raise)" : "var(--a-bet1)";
        const rank = aggr.indexOf(i);
        if (rank === 0) return "var(--a-bet1)";
        if (rank === aggr.length - 1) return "var(--a-bet2)";
        return "var(--a-raise)";
      }
    }
  });
}

// ── Tooltip ───────────────────────────────────────────────
const tip = () => document.getElementById("tooltip");
let tipOwner = null;

function place(x, y) {
  const t = tip();
  const pad = 14, w = t.offsetWidth, h = t.offsetHeight;
  let left = x + pad, top = y + pad;
  if (left + w > innerWidth - 8) left = x - w - pad;
  if (top + h > innerHeight - 8) top = y - h - pad;
  t.style.left = `${Math.max(8, left)}px`;
  t.style.top = `${Math.max(8, top)}px`;
}

export function showTip(html, x, y, owner) {
  const t = tip();
  t.innerHTML = html;
  t.hidden = false;
  tipOwner = owner;
  place(x, y);
}
export function hideTip(owner) { if (!owner || owner === tipOwner) { tip().hidden = true; tipOwner = null; } }

/** Delegated tooltips: any element with `data-tip` inside `root` (html built by `lookup(key)`). */
export function bindTips(root, lookup) {
  const html = (el) => lookup(el.dataset.tip, el);
  root.addEventListener("pointermove", (e) => {
    const el = e.target.closest?.("[data-tip]");
    if (!el || !root.contains(el)) return hideTip();
    const h = html(el);
    if (h) showTip(h, e.clientX, e.clientY, el); else hideTip();
  });
  root.addEventListener("pointerleave", () => hideTip());
  root.addEventListener("focusin", (e) => {
    const el = e.target.closest?.("[data-tip]");
    if (!el) return;
    const r = el.getBoundingClientRect();
    const h = html(el);
    if (h) showTip(h, r.left + r.width / 2, r.top + r.height / 2, el);
  });
  root.addEventListener("focusout", () => hideTip());
}

export function ttRows(rows) {
  return rows.filter(Boolean).map(([k, v]) => `<div class="tt-row"><span>${esc(k)}</span><span>${esc(v)}</span></div>`).join("");
}

/** Status icon + label for an EV loss (fraction of pot). */
export function lossStatus(lossPot, valid, best = 0.0025, blunder = 0.25) {
  if (!valid) return { cls: "bad", text: "invalid", icon: "x" };
  if (lossPot <= best) return { cls: "good", text: "best EV", icon: "check" };
  if (lossPot > blunder) return { cls: "bad", text: `−${(lossPot * 100).toFixed(1)}% pot`, icon: "x" };
  return { cls: "warn", text: `−${(lossPot * 100).toFixed(1)}% pot`, icon: "dot" };
}
export function statusHTML(s) {
  const icon = s.icon === "check" ? `<svg viewBox="0 0 12 12" aria-hidden="true"><path d="M2 6.5l2.5 2.5L10 3.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>`
    : s.icon === "x" ? `<svg viewBox="0 0 12 12" aria-hidden="true"><path d="M3 3l6 6M9 3l-6 6" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>`
    : `<svg viewBox="0 0 12 12" aria-hidden="true"><circle cx="6" cy="6" r="3" fill="currentColor"/></svg>`;
  return `<span class="status ${s.cls}">${icon}${esc(s.text)}</span>`;
}

/** Name without the provider prefix, for narrow charts ("TypeSafe Jev 1.13" → "Jev 1.13"). */
export function shortName(p) {
  if (p.kind === "baseline") return p.name;
  const words = (p.provider || "").split(/\s+/)[0];
  if (words && p.name.toLowerCase().startsWith(words.toLowerCase() + " ")) {
    const rest = p.name.slice(words.length + 1);
    return rest.length >= 3 ? rest : p.name;
  }
  return p.name;
}

export function debounce(fn, ms = 120) {
  let t;
  return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); };
}
