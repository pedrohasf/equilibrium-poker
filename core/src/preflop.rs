//! Heads-up preflop solver (SB = button vs BB).
//!
//! The preflop betting tree (fold / limp / open / 3-bet / 4-bet / all-in) is
//! solved with the same Discounted CFR as the postflop engine. Terminals:
//! * fold — exact;
//! * all-in called — exact chip EV from a 169×169 hand-class equity matrix;
//! * flop reached — pot × *realised* equity: the out-of-position BB realises
//!   `eqr_oop` of its raw equity at deep SPR (→ 1.0 as SPR → 0); the in-position
//!   SB gets the rest. This equity-realisation model is the standard
//!   approximation of preflop-only solvers.
//!
//! With small stacks and no open sizes the tree is push/fold, which is exact.
//! Player 0 = SB (acts first preflop, in position postflop), player 1 = BB.
//! Values are net chips relative to the start of the hand (blinds and ante paid).

use crate::cards::{combos, combo_to_string, Card, NUM_COMBOS};
use crate::equity::Rng;
use crate::eval::eval;
use crate::range::parse_range;
use crate::solver::{average_strategy, discount_params, regret_match, ActionInfo, HandInfo, NodeInfo, PlayerView, Progress};
use crate::tree::{Action, ActionKind};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;
use std::time::Instant;

pub const SB: usize = 0;
pub const BB: usize = 1;
const NAMES: [&str; 2] = ["SB", "BB"];

fn d_true() -> bool {
    true
}
fn d_eqr() -> f32 {
    0.88
}
fn d_eqr_ip() -> f32 {
    1.05
}
fn d_raises() -> u32 {
    4
}
fn d_open() -> Vec<f32> {
    vec![2.5]
}
fn d_three() -> Vec<f32> {
    vec![3.5]
}
fn d_four() -> Vec<f32> {
    vec![2.3]
}
fn d_iso() -> Vec<f32> {
    vec![3.5]
}
fn d_thresh() -> f32 {
    0.6
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct PreflopConfig {
    /// Effective stack in bb, including the posted blind.
    pub stack: f32,
    /// Dead money paid by the BB (big-blind ante), in bb.
    #[serde(default)]
    pub ante: f32,
    /// SB open sizes ("raise to", bb). Empty + `allow_limp = false` = push/fold.
    #[serde(default = "d_open")]
    pub open_sizes: Vec<f32>,
    #[serde(default = "d_true")]
    pub allow_limp: bool,
    /// BB raise-to sizes after a limp (bb).
    #[serde(default = "d_iso")]
    pub iso_sizes: Vec<f32>,
    /// 3-bet sizes as a multiple of the facing raise-to.
    #[serde(default = "d_three")]
    pub threebet: Vec<f32>,
    /// 4-bet+ sizes as a multiple of the facing raise-to.
    #[serde(default = "d_four")]
    pub fourbet: Vec<f32>,
    #[serde(default = "d_true")]
    pub allin: bool,
    /// Raises above this fraction of the stack become all-in.
    #[serde(default = "d_thresh")]
    pub allin_threshold: f32,
    #[serde(default = "d_raises")]
    pub max_raises: u32,
    /// Equity realisation of the out-of-position BB at deep SPR (→ 1 as SPR → 0).
    #[serde(default = "d_eqr")]
    pub eqr_oop: f32,
    /// Equity realisation of the in-position SB at deep SPR (→ 1 as SPR → 0).
    #[serde(default = "d_eqr_ip")]
    pub eqr_ip: f32,
    /// Optional starting ranges (default: every hand).
    #[serde(default)]
    pub range_sb: Option<String>,
    #[serde(default)]
    pub range_bb: Option<String>,
}

impl PreflopConfig {
    /// Push/fold for the SB, call/fold for the BB.
    pub fn push_fold(stack: f32, ante: f32) -> Self {
        PreflopConfig {
            stack,
            ante,
            open_sizes: vec![],
            allow_limp: false,
            iso_sizes: vec![],
            threebet: vec![],
            fourbet: vec![],
            allin: true,
            allin_threshold: 0.6,
            max_raises: 1,
            eqr_oop: 0.88,
            eqr_ip: 1.05,
            range_sb: None,
            range_bb: None,
        }
    }
}

// ------------------------------------------------------------------ equity matrix

/// 169 hand classes: pairs r*13+r, suited hi*13+lo, offsuit lo*13+hi (hi > lo).
pub fn class_of(c: [Card; 2]) -> usize {
    let (r0, r1) = ((c[0] >> 2) as usize, (c[1] >> 2) as usize);
    let (hi, lo) = if r0 >= r1 { (r0, r1) } else { (r1, r0) };
    if hi == lo {
        hi * 13 + hi
    } else if c[0] & 3 == c[1] & 3 {
        hi * 13 + lo
    } else {
        lo * 13 + hi
    }
}

/// `m[a * 169 + b]` = all-in equity of class a vs class b (Monte-Carlo, cached per process).
pub fn equity_matrix() -> &'static Vec<f32> {
    static M: OnceLock<Vec<f32>> = OnceLock::new();
    M.get_or_init(|| {
        let all = combos();
        let mut by_class: Vec<Vec<[Card; 2]>> = vec![Vec::new(); 169];
        for c in all.iter() {
            by_class[class_of(*c)].push(*c);
        }
        const N: usize = 6000;
        let pairs: Vec<(usize, usize)> = (0..169).flat_map(|a| (a..169).map(move |b| (a, b))).collect();
        let vals: Vec<f32> = pairs
            .par_iter()
            .map(|&(a, b)| {
                let mut rng = Rng::new((a * 1000 + b) as u64 * 7919);
                let (ca, cb) = (&by_class[a], &by_class[b]);
                let mut total = 0.0f64;
                let mut n = 0usize;
                let mut seven_a = [0u8; 7];
                let mut seven_b = [0u8; 7];
                while n < N {
                    let x = ca[rng.below(ca.len())];
                    let y = cb[rng.below(cb.len())];
                    let mut used: u64 = (1 << x[0]) | (1 << x[1]);
                    if used & ((1 << y[0]) | (1 << y[1])) != 0 {
                        continue;
                    }
                    used |= (1 << y[0]) | (1 << y[1]);
                    let mut k = 0;
                    while k < 5 {
                        let c = rng.below(52) as u8;
                        if used & (1 << c) == 0 {
                            used |= 1 << c;
                            seven_a[k] = c;
                            seven_b[k] = c;
                            k += 1;
                        }
                    }
                    seven_a[5] = x[0];
                    seven_a[6] = x[1];
                    seven_b[5] = y[0];
                    seven_b[6] = y[1];
                    let (ea, eb) = (eval(&seven_a), eval(&seven_b));
                    total += if ea > eb { 1.0 } else if ea == eb { 0.5 } else { 0.0 };
                    n += 1;
                }
                (total / N as f64) as f32
            })
            .collect();
        let mut m = vec![0.5f32; 169 * 169];
        for (&(a, b), &v) in pairs.iter().zip(&vals) {
            if a == b {
                m[a * 169 + a] = 0.5;
            } else {
                m[a * 169 + b] = v;
                m[b * 169 + a] = 1.0 - v;
            }
        }
        m
    })
}

// ------------------------------------------------------------------ tree

#[derive(Clone, Copy, Debug, PartialEq)]
enum TermKind {
    Fold(usize),
    Flop,
    Allin,
}

enum PNode {
    Action {
        player: usize,
        actions: Vec<Action>,
        children: Vec<PNode>,
        regrets: Vec<f32>,
        strat_sum: Vec<f32>,
        contrib: [f32; 2],
    },
    Terminal {
        kind: TermKind,
        contrib: [f32; 2],
        /// For flop terminals: realised pot share of class a (hero) vs class b, per hero seat.
        share: Option<std::sync::Arc<[Vec<f32>; 2]>>,
    },
}

impl PNode {
    fn contrib(&self) -> [f32; 2] {
        match self {
            PNode::Action { contrib, .. } | PNode::Terminal { contrib, .. } => *contrib,
        }
    }
}

struct Builder<'a> {
    cfg: &'a PreflopConfig,
    nodes: usize,
}

const EPS: f32 = 1e-4;

impl<'a> Builder<'a> {
    /// Flop terminal with an equity-realisation share matrix:
    /// SB share = e·Rip / (e·Rip + (1−e)·Roop), both factors → 1 as SPR → 0.
    fn flop(&mut self, c: [f32; 2]) -> PNode {
        let pot = c[0] + c[1] + self.cfg.ante;
        let spr = (self.cfg.stack - c[0].max(c[1])) / pot.max(1e-6);
        let t = (spr / 4.0).min(1.0);
        let r_oop = 1.0 - (1.0 - self.cfg.eqr_oop) * t;
        let r_ip = 1.0 + (self.cfg.eqr_ip - 1.0) * t;
        let m = equity_matrix();
        let mut sb = vec![0.5f32; 169 * 169];
        let mut bb = vec![0.5f32; 169 * 169];
        for a in 0..169 {
            for b in 0..169 {
                let e = m[a * 169 + b]; // SB class a vs BB class b
                let x = e * r_ip;
                let y = (1.0 - e) * r_oop;
                let share = if x + y > 0.0 { x / (x + y) } else { 0.5 };
                sb[a * 169 + b] = share;
                bb[b * 169 + a] = 1.0 - share;
            }
        }
        PNode::Terminal { kind: TermKind::Flop, contrib: c, share: Some(std::sync::Arc::new([sb, bb])) }
    }

    fn node(&mut self, p: usize, c: [f32; 2], raises: u32, limped: bool) -> PNode {
        let q = 1 - p;
        let s = self.cfg.stack;
        let facing = c[q] - c[p];
        let mut actions: Vec<Action> = Vec::new();
        let push_raise = |actions: &mut Vec<Action>, mut to: f32| {
            let min_to = c[q] + facing.max(1.0);
            to = to.max(min_to);
            if to >= s * self.cfg.allin_threshold || to >= s - EPS {
                to = s;
            }
            if to <= c[q] + EPS || actions.iter().any(|a| (a.to - to).abs() < 0.05) {
                return;
            }
            let kind = if (to - s).abs() < EPS { ActionKind::Allin } else { ActionKind::Raise };
            actions.push(Action { kind, amount: to - c[p], to, pot_fraction: 0.0 });
        };
        if facing <= EPS {
            // BB after a limp
            actions.push(Action { kind: ActionKind::Check, amount: 0.0, to: c[p], pot_fraction: 0.0 });
            if raises < self.cfg.max_raises {
                for &t in &self.cfg.iso_sizes {
                    push_raise(&mut actions, t);
                }
                if self.cfg.allin {
                    push_raise(&mut actions, s);
                }
            }
        } else {
            actions.push(Action { kind: ActionKind::Fold, amount: 0.0, to: c[p], pot_fraction: 0.0 });
            let first = p == SB && raises == 0;
            let call_to = c[q].min(s);
            if !first || self.cfg.allow_limp {
                actions.push(Action { kind: ActionKind::Call, amount: call_to - c[p], to: call_to, pot_fraction: 0.0 });
            }
            if raises < self.cfg.max_raises && c[q] < s - EPS {
                if first {
                    for &t in &self.cfg.open_sizes {
                        push_raise(&mut actions, t);
                    }
                } else {
                    let mults = if raises == 1 && !limped { &self.cfg.threebet } else { &self.cfg.fourbet };
                    for &m in mults {
                        push_raise(&mut actions, m * c[q]);
                    }
                }
                if self.cfg.allin {
                    push_raise(&mut actions, s);
                }
            }
        }
        let mut children = Vec::with_capacity(actions.len());
        for a in &actions {
            let child = match a.kind {
                ActionKind::Fold => PNode::Terminal { kind: TermKind::Fold(p), contrib: c, share: None },
                ActionKind::Check => self.flop(c),
                ActionKind::Call => {
                    let mut c2 = c;
                    c2[p] = a.to;
                    if p == SB && raises == 0 {
                        // limp: BB gets an option
                        self.node(BB, c2, raises, true)
                    } else if (c2[p] - s).abs() < EPS {
                        PNode::Terminal { kind: TermKind::Allin, contrib: c2, share: None }
                    } else {
                        self.flop(c2)
                    }
                }
                _ => {
                    let mut c2 = c;
                    c2[p] = a.to;
                    self.node(q, c2, raises + 1, limped)
                }
            };
            children.push(child);
        }
        self.nodes += 1;
        let n = actions.len() * NUM_COMBOS;
        PNode::Action { player: p, actions, children, regrets: vec![0.0; n], strat_sum: vec![0.0; n], contrib: c }
    }
}

fn preflop_label(a: &Action, p: usize, raises_before: bool) -> String {
    let fmt = crate::tree::fmt_chips;
    match a.kind {
        ActionKind::Fold => "Fold".into(),
        ActionKind::Check => "Check".into(),
        ActionKind::Call if p == SB && !raises_before => "Limp (call 0.5)".into(),
        ActionKind::Call => format!("Call {}", fmt(a.amount)),
        ActionKind::Allin => format!("All-in {}", fmt(a.to)),
        _ => format!("Raise to {}", fmt(a.to)),
    }
}

// ------------------------------------------------------------------ game

pub struct PreflopSolver {
    pub cfg: PreflopConfig,
    root: PNode,
    weights: [Vec<f32>; 2],
    class: Vec<u16>,
    card_combos: Vec<Vec<u16>>,
    pub iteration: u32,
    pub exploitability: f32,
    pub elapsed: f64,
    pub nodes: usize,
}

impl PreflopSolver {
    pub fn new(cfg: PreflopConfig) -> Result<Self, String> {
        if !(cfg.stack >= 1.0) {
            return Err("stack must be at least 1bb".into());
        }
        let w = |r: &Option<String>| -> Result<Vec<f32>, String> {
            match r {
                Some(t) if !t.trim().is_empty() => parse_range(t),
                _ => Ok(vec![1.0; NUM_COMBOS]),
            }
        };
        let weights = [w(&cfg.range_sb)?, w(&cfg.range_bb)?];
        let mut b = Builder { cfg: &cfg, nodes: 0 };
        let root = b.node(SB, [0.5f32.min(cfg.stack), 1.0f32.min(cfg.stack)], 0, false);
        let nodes = b.nodes;
        let all = combos();
        let class = all.iter().map(|c| class_of(*c) as u16).collect();
        let mut card_combos = vec![Vec::new(); 52];
        for (i, c) in all.iter().enumerate() {
            card_combos[c[0] as usize].push(i as u16);
            card_combos[c[1] as usize].push(i as u16);
        }
        equity_matrix();
        Ok(PreflopSolver { cfg, root, weights, class, card_combos, iteration: 0, exploitability: f32::INFINITY, elapsed: 0.0, nodes })
    }

    fn paid(&self, contrib: [f32; 2]) -> [f32; 2] {
        [contrib[0], contrib[1] + self.cfg.ante]
    }

    /// (compatible opponent mass, Σ compatible reach × m(hero, opp)) per hero combo,
    /// where `m` is a 169×169 class matrix (raw equity by default).
    fn masses(&self, opp: &[f32]) -> (Vec<f32>, Vec<f32>) {
        self.masses_with(opp, equity_matrix())
    }

    fn masses_with(&self, opp: &[f32], m: &[f32]) -> (Vec<f32>, Vec<f32>) {
        let all = combos();
        let mut total = 0.0f32;
        let mut by_class = [0.0f32; 169];
        let mut by_card = [0.0f32; 52];
        for (o, &r) in opp.iter().enumerate() {
            if r != 0.0 {
                total += r;
                by_class[self.class[o] as usize] += r;
                let c = all[o];
                by_card[c[0] as usize] += r;
                by_card[c[1] as usize] += r;
            }
        }
        // per hero class: Σ_c M[h][c] R[c]
        let base: Vec<f32> = (0..169).map(|h| (0..169).map(|c| m[h * 169 + c] * by_class[c]).sum()).collect();
        let mut compat = vec![0.0f32; NUM_COMBOS];
        let mut eqs = vec![0.0f32; NUM_COMBOS];
        for (h, c) in all.iter().enumerate() {
            let ch = self.class[h] as usize;
            compat[h] = total - by_card[c[0] as usize] - by_card[c[1] as usize] + opp[h];
            let mut conflict = 0.0f32;
            for &card in c {
                for &o in &self.card_combos[card as usize] {
                    let r = opp[o as usize];
                    if r != 0.0 {
                        conflict += r * m[ch * 169 + self.class[o as usize] as usize];
                    }
                }
            }
            eqs[h] = base[ch] - conflict + opp[h] * m[ch * 169 + ch];
        }
        (compat, eqs)
    }

    fn terminal(&self, kind: TermKind, contrib: [f32; 2], share: &Option<std::sync::Arc<[Vec<f32>; 2]>>, p: usize, opp: &[f32]) -> Vec<f32> {
        let paid = self.paid(contrib);
        let pot = paid[0] + paid[1];
        let (compat, eqs) = match share {
            Some(sh) => self.masses_with(opp, &sh[p]),
            None => self.masses(opp),
        };
        match kind {
            TermKind::Fold(f) => {
                let u = if f == p { -paid[p] } else { pot - paid[p] };
                compat.iter().map(|m| m * u).collect()
            }
            TermKind::Allin | TermKind::Flop => (0..NUM_COMBOS).map(|h| pot * eqs[h] - paid[p] * compat[h]).collect(),
        }
    }

    fn cfr(&self, node: &mut PNode, p: usize, hero: &[f32], opp: &[f32], d: crate::solver::Discount) -> Vec<f32> {
        match node {
            PNode::Terminal { kind, contrib, share } => self.terminal(*kind, *contrib, share, p, opp),
            PNode::Action { player, children, regrets, strat_sum, .. } => {
                let na = children.len();
                let n = NUM_COMBOS;
                let strat = regret_match(regrets, na, n);
                if *player == p {
                    let vals: Vec<Vec<f32>> = children
                        .iter_mut()
                        .enumerate()
                        .map(|(i, c)| {
                            let r: Vec<f32> = (0..n).map(|h| hero[h] * strat[i * n + h]).collect();
                            self.cfr(c, p, &r, opp, d)
                        })
                        .collect();
                    let mut v = vec![0.0f32; n];
                    for i in 0..na {
                        for h in 0..n {
                            v[h] += strat[i * n + h] * vals[i][h];
                        }
                    }
                    for i in 0..na {
                        for h in 0..n {
                            let k = i * n + h;
                            let old = regrets[k];
                            regrets[k] = old * if old > 0.0 { d.pos } else { d.neg } + vals[i][h] - v[h];
                            strat_sum[k] = strat_sum[k] * d.strat + hero[h] * strat[k];
                        }
                    }
                    v
                } else {
                    let mut v = vec![0.0f32; n];
                    for (i, c) in children.iter_mut().enumerate() {
                        let r: Vec<f32> = (0..n).map(|o| opp[o] * strat[i * n + o]).collect();
                        if r.iter().all(|&x| x == 0.0) {
                            continue;
                        }
                        let cv = self.cfr(c, p, hero, &r, d);
                        v.iter_mut().zip(&cv).for_each(|(a, b)| *a += b);
                    }
                    v
                }
            }
        }
    }

    fn evaluate(&self, node: &PNode, p: usize, opp: &[f32], br: bool) -> Vec<f32> {
        match node {
            PNode::Terminal { kind, contrib, share } => self.terminal(*kind, *contrib, share, p, opp),
            PNode::Action { player, children, strat_sum, .. } => {
                let na = children.len();
                let n = NUM_COMBOS;
                let strat = average_strategy(strat_sum, na, n);
                if *player == p {
                    let vals: Vec<Vec<f32>> = children.iter().map(|c| self.evaluate(c, p, opp, br)).collect();
                    (0..n)
                        .map(|h| {
                            if br {
                                vals.iter().map(|v| v[h]).fold(f32::NEG_INFINITY, f32::max)
                            } else {
                                (0..na).map(|i| strat[i * n + h] * vals[i][h]).sum()
                            }
                        })
                        .collect()
                } else {
                    let mut v = vec![0.0f32; n];
                    for (i, c) in children.iter().enumerate() {
                        let r: Vec<f32> = (0..n).map(|o| opp[o] * strat[i * n + o]).collect();
                        if r.iter().all(|&x| x == 0.0) {
                            continue;
                        }
                        let cv = self.evaluate(c, p, &r, br);
                        v.iter_mut().zip(&cv).for_each(|(a, b)| *a += b);
                    }
                    v
                }
            }
        }
    }

    pub fn iterate(&mut self) {
        let d = discount_params(self.iteration);
        let mut root = std::mem::replace(&mut self.root, PNode::Terminal { kind: TermKind::Flop, contrib: [0.0; 2], share: None });
        for p in 0..2 {
            let (hero, opp) = (self.weights[p].clone(), self.weights[1 - p].clone());
            self.cfr(&mut root, p, &hero, &opp, d);
        }
        self.root = root;
        self.iteration += 1;
    }

    /// Exploitability in milli-big-blinds per hand.
    pub fn compute_exploitability(&mut self) -> f32 {
        let mass: f64 = {
            let (compat, _) = self.masses(&self.weights[1]);
            compat.iter().zip(&self.weights[0]).map(|(m, w)| (*m as f64) * (*w as f64)).sum()
        };
        let mut br = [0f64; 2];
        for p in 0..2 {
            let v = self.evaluate(&self.root, p, &self.weights[1 - p], true);
            br[p] = v.iter().zip(&self.weights[p]).map(|(x, w)| (*x as f64) * (*w as f64)).sum::<f64>() / mass;
        }
        self.exploitability = (((br[0] + br[1]) / 2.0) * 1000.0).max(0.0) as f32;
        self.exploitability
    }

    pub fn solve(&mut self, max_iterations: u32, target_mbb: f32, check_every: u32, stop: &AtomicBool, mut cb: impl FnMut(Progress)) -> Progress {
        let check = check_every.max(1);
        while self.iteration < max_iterations && !stop.load(Ordering::Relaxed) {
            let t0 = Instant::now();
            self.iterate();
            self.elapsed += t0.elapsed().as_secs_f64();
            if self.iteration % check == 0 || self.iteration == max_iterations {
                let e = self.compute_exploitability();
                cb(self.progress());
                if e <= target_mbb {
                    break;
                }
            }
        }
        if self.iteration % check != 0 {
            self.compute_exploitability();
        }
        self.progress()
    }

    pub fn progress(&self) -> Progress {
        Progress { iteration: self.iteration, exploitability: self.exploitability, elapsed: self.elapsed }
    }

    /// Node description in the same shape as postflop queries (street "preflop", empty board).
    /// `ev` / `action_evs` are node-relative: expected chips won from here on minus future investment.
    pub fn query(&self, path: &[usize]) -> Result<NodeInfo, String> {
        let mut node = &self.root;
        let mut reach = self.weights.clone();
        let mut history = Vec::new();
        let mut raised = false;
        for &i in path {
            match node {
                PNode::Action { player, actions, children, strat_sum, .. } => {
                    if i >= children.len() {
                        return Err(format!("action index {i} out of range"));
                    }
                    let strat = average_strategy(strat_sum, children.len(), NUM_COMBOS);
                    for h in 0..NUM_COMBOS {
                        reach[*player][h] *= strat[i * NUM_COMBOS + h];
                    }
                    history.push(format!("{}: {}", NAMES[*player], preflop_label(&actions[i], *player, raised)));
                    if actions[i].kind == ActionKind::Raise || actions[i].kind == ActionKind::Allin {
                        raised = true;
                    }
                    if actions[i].kind == ActionKind::Call {
                        raised = true;
                    }
                    node = &children[i];
                }
                PNode::Terminal { .. } => return Err("path continues past a terminal node".into()),
            }
        }
        let contrib = node.contrib();
        let paid = self.paid(contrib);
        let pot = paid[0] + paid[1];
        let (kind, player, actions, terminal) = match node {
            PNode::Action { player, actions, .. } => (
                "action",
                Some(*player),
                actions
                    .iter()
                    .map(|a| ActionInfo {
                        label: preflop_label(a, *player, raised),
                        kind: a.kind,
                        amount: a.amount,
                        to: a.to,
                        pot_fraction: a.amount / pot,
                    })
                    .collect(),
                None,
            ),
            PNode::Terminal { kind, .. } => (
                "terminal",
                None,
                vec![],
                Some(match kind {
                    TermKind::Fold(p) => format!("{} folds", NAMES[*p]),
                    TermKind::Flop => "Flop".to_string(),
                    TermKind::Allin => "All-in showdown".to_string(),
                }),
            ),
        };
        let all = combos();
        let mut players = Vec::new();
        for p in 0..2 {
            let opp = &reach[1 - p];
            let (compat, eqs) = self.masses(opp);
            let norm = |v: &[f32]| -> Vec<f32> {
                (0..NUM_COMBOS).map(|h| if compat[h] > 1e-9 { v[h] / compat[h] + paid[p] } else { 0.0 }).collect()
            };
            let (strategy, action_evs, ev) = match node {
                PNode::Action { player: ap, children, strat_sum, .. } if *ap == p => {
                    let na = children.len();
                    let s = average_strategy(strat_sum, na, NUM_COMBOS);
                    let raw: Vec<Vec<f32>> = children.iter().map(|c| self.evaluate(c, p, opp, false)).collect();
                    let tot: Vec<f32> = (0..NUM_COMBOS).map(|h| (0..na).map(|i| s[i * NUM_COMBOS + h] * raw[i][h]).sum()).collect();
                    (Some((s, na)), raw.iter().map(|v| norm(v)).collect::<Vec<_>>(), norm(&tot))
                }
                _ => (None, vec![], norm(&self.evaluate(node, p, opp, false))),
            };
            let mut hands = Vec::new();
            for h in 0..NUM_COMBOS {
                let r = reach[p][h];
                if r <= 1e-7 {
                    continue;
                }
                hands.push(HandInfo {
                    combo: combo_to_string(all[h]),
                    weight: self.weights[p][h],
                    reach: r,
                    strategy: strategy.as_ref().map(|(s, na)| (0..*na).map(|i| s[i * NUM_COMBOS + h]).collect()).unwrap_or_default(),
                    action_evs: action_evs.iter().map(|v| v[h]).collect(),
                    ev: ev[h],
                    equity: if compat[h] > 1e-9 { eqs[h] / compat[h] } else { 0.0 },
                });
            }
            players.push(PlayerView { combos: reach[p].iter().sum(), hands });
        }
        Ok(NodeInfo {
            kind: kind.into(),
            street: "preflop".into(),
            board: vec![],
            pot,
            starting_pot: 1.5 + self.cfg.ante,
            contrib,
            stacks: [self.cfg.stack - contrib[0], self.cfg.stack - contrib[1]],
            player,
            actions,
            chance_cards: vec![],
            terminal,
            history,
            players,
            iteration: self.iteration,
            exploitability: self.exploitability,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matrix_sane() {
        let m = equity_matrix();
        let aa = 12 * 13 + 12;
        let kk = 11 * 13 + 11;
        let seven_two_o = 0 * 13 + 5; // offsuit: lo*13+hi with hi=7 (rank 5), lo=2 (rank 0)
        assert!((m[aa * 169 + kk] - 0.82).abs() < 0.02, "AA vs KK {}", m[aa * 169 + kk]);
        assert!((m[aa * 169 + seven_two_o] - 0.87).abs() < 0.03, "AA vs 72o {}", m[aa * 169 + seven_two_o]);
    }

    #[test]
    fn push_fold_10bb() {
        let mut s = PreflopSolver::new(PreflopConfig::push_fold(10.0, 0.0)).unwrap();
        let stop = AtomicBool::new(false);
        let p = s.solve(3000, 1.0, 100, &stop, |_| {});
        assert!(p.exploitability < 5.0, "expl {} mbb", p.exploitability);
        let root = s.query(&[]).unwrap();
        let freq = |combo: &str, i: usize| root.players[0].hands.iter().find(|h| h.combo == combo).unwrap().strategy[i];
        // 10bb HU Nash: SB jams ~58% of hands: AA always, 72o folds, K2o jams
        let jam = root.actions.iter().position(|a| a.kind == ActionKind::Allin).unwrap();
        assert!(freq("AsAh", jam) > 0.99);
        assert!(freq("7s2h", jam) < 0.2, "72o jam {}", freq("7s2h", jam));
        assert!(freq("Ks2h", jam) > 0.8, "K2o jam {}", freq("Ks2h", jam));
        let total: f32 = root.players[0].hands.iter().map(|h| h.strategy[jam] * h.reach).sum::<f32>()
            / root.players[0].hands.iter().map(|h| h.reach).sum::<f32>();
        assert!((0.5..0.7).contains(&total), "jam freq {total}");
    }

    #[test]
    fn deep_tree_solves() {
        let cfg: PreflopConfig = serde_json::from_value(serde_json::json!({"stack": 100.0})).unwrap();
        let mut s = PreflopSolver::new(cfg).unwrap();
        let stop = AtomicBool::new(false);
        let p = s.solve(2000, 5.0, 100, &stop, |_| {});
        assert!(p.exploitability < 25.0, "expl {} mbb", p.exploitability);
        let root = s.query(&[]).unwrap();
        let f = root.actions.iter().position(|a| a.kind == ActionKind::Fold).unwrap();
        let fold: f32 = root.players[0].hands.iter().map(|h| h.strategy[f] * h.reach).sum::<f32>()
            / root.players[0].hands.iter().map(|h| h.reach).sum::<f32>();
        assert!(fold < 0.4, "SB folds {fold} at 100bb");
    }
}
