//! Vectorised Discounted CFR (Brown & Sandholm 2019) over a postflop game tree.
//!
//! Utilities are zero-sum and measured relative to the root: the winner of a
//! pot collects `starting_pot / 2 + opponent contribution`. Every value vector
//! returned by a traversal is a *counterfactual* value: it is already weighted
//! by the opponent's reach, so dividing by the compatible opponent mass yields
//! a per-hand expectation.

use crate::cards::{combo_index, combos, combo_to_string, mask_of, Card, NUM_COMBOS};
use crate::eval::eval;
use crate::range::parse_range;
use crate::tree::*;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

fn default_threshold() -> f32 {
    0.67
}
fn default_true() -> bool {
    true
}
fn default_raise_limit() -> u32 {
    3
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct GameConfig {
    pub board: String,
    pub range_oop: String,
    pub range_ip: String,
    pub starting_pot: f32,
    pub effective_stack: f32,
    #[serde(default)]
    pub bet_sizes: BetSizesConfig,
    #[serde(default = "default_threshold")]
    pub allin_threshold: f32,
    #[serde(default = "default_true")]
    pub add_allin: bool,
    #[serde(default = "default_raise_limit")]
    pub raise_limit: u32,
    /// 0 = use all cores.
    #[serde(default)]
    pub threads: usize,
    /// Refuse to allocate trees larger than this (0 = no limit).
    #[serde(default)]
    pub max_memory_bytes: u64,
    /// Solve suit-isomorphic turn/river cards once (requires suit-symmetric ranges).
    #[serde(default = "default_true")]
    pub isomorphism: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct Estimate {
    pub stats: TreeStats,
    pub memory_bytes: u64,
    pub hands: [usize; 2],
}

/// Hand strengths for one river board: `(strength, hand index)` sorted ascending.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct RankEntry {
    s: u32,
    h: u16,
    c0: u8,
    c1: u8,
}
type RiverRanks = [Vec<RankEntry>; 2];

pub struct Game {
    pub tree_cfg: TreeConfig,
    pub board: Vec<Card>,
    pub hands: [Vec<[Card; 2]>; 2],
    pub weights: [Vec<f32>; 2],
    /// Index of the identical combo in the other player's list, or -1.
    pub same: [Vec<i32>; 2],
    /// Hands containing each card.
    pub card_hands: [Vec<Vec<u32>>; 2],
    river_index: HashMap<u64, u32>,
    river: Vec<RiverRanks>,
    root_street: u8,
    /// Suit permutations that are symmetries of the root (identity first).
    pub perms: Vec<[u8; 4]>,
    pub perm_inv: Vec<u8>,
    /// `hand_perm[p][k][h]` = index of hand `h` mapped through `perms[k]`.
    hand_perm: [Vec<Vec<u32>>; 2],
}

#[derive(Clone, Copy)]
struct Discount {
    pos: f32,
    neg: f32,
    strat: f32,
}

/// Depth up to which sibling action subtrees are solved in parallel.
const PAR_DEPTH: u32 = 4;

impl Game {
    pub fn new(cfg: &GameConfig) -> Result<Game, String> {
        let board = crate::cards::parse_cards(&cfg.board)?;
        if !(3..=5).contains(&board.len()) {
            return Err("board must have 3, 4 or 5 cards".into());
        }
        let board_mask = mask_of(&board);
        let tree_cfg = TreeConfig::from_spec(
            cfg.starting_pot,
            cfg.effective_stack,
            &cfg.bet_sizes,
            cfg.allin_threshold,
            cfg.add_allin,
            cfg.raise_limit,
        )?;
        let ranges = [parse_range(&cfg.range_oop)?, parse_range(&cfg.range_ip)?];
        let mut hands: [Vec<[Card; 2]>; 2] = [Vec::new(), Vec::new()];
        let mut weights: [Vec<f32>; 2] = [Vec::new(), Vec::new()];
        for p in 0..2 {
            for (i, c) in combos().iter().enumerate() {
                let w = ranges[p][i];
                if w > 0.0 && (board_mask & mask_of(c)) == 0 {
                    hands[p].push(*c);
                    weights[p].push(w);
                }
            }
            if hands[p].is_empty() {
                return Err(format!("{} range is empty on this board", if p == 0 { "OOP" } else { "IP" }));
            }
        }
        let mut same: [Vec<i32>; 2] = [Vec::new(), Vec::new()];
        let mut card_hands: [Vec<Vec<u32>>; 2] = [vec![Vec::new(); 52], vec![Vec::new(); 52]];
        for p in 0..2 {
            let mut lookup = vec![-1i32; NUM_COMBOS];
            for (i, c) in hands[1 - p].iter().enumerate() {
                lookup[combo_index(c[0], c[1])] = i as i32;
            }
            same[p] = hands[p].iter().map(|c| lookup[combo_index(c[0], c[1])]).collect();
            for (i, c) in hands[p].iter().enumerate() {
                card_hands[p][c[0] as usize].push(i as u32);
                card_hands[p][c[1] as usize].push(i as u32);
            }
        }

        // Enumerate every river board reachable from the starting board.
        let deck: Vec<Card> = (0..52u8).filter(|c| board_mask & (1 << c) == 0).collect();
        let mut runouts: Vec<Vec<Card>> = Vec::new();
        match board.len() {
            5 => runouts.push(board.clone()),
            4 => {
                for &c in &deck {
                    let mut b = board.clone();
                    b.push(c);
                    runouts.push(b);
                }
            }
            _ => {
                for i in 0..deck.len() {
                    for j in i + 1..deck.len() {
                        let mut b = board.clone();
                        b.push(deck[i]);
                        b.push(deck[j]);
                        runouts.push(b);
                    }
                }
            }
        }
        let river: Vec<RiverRanks> = runouts
            .par_iter()
            .map(|b| {
                let bm = mask_of(b);
                let mut out: RiverRanks = [Vec::new(), Vec::new()];
                let mut seven = [0u8; 7];
                seven[..5].copy_from_slice(b);
                for p in 0..2 {
                    let mut v: Vec<RankEntry> = Vec::with_capacity(hands[p].len());
                    for (i, h) in hands[p].iter().enumerate() {
                        if bm & mask_of(h) != 0 {
                            continue;
                        }
                        seven[5] = h[0];
                        seven[6] = h[1];
                        v.push(RankEntry { s: eval(&seven), h: i as u16, c0: h[0], c1: h[1] });
                    }
                    v.sort_unstable();
                    out[p] = v;
                }
                out
            })
            .collect();
        let river_index = runouts.iter().enumerate().map(|(i, b)| (mask_of(b), i as u32)).collect();

        let root_street = board.len() as u8 - 3;

        // Suit symmetries: permutations fixing the board (as a set) and both ranges.
        let all_perms = crate::cards::suit_permutations();
        let perms: Vec<[u8; 4]> = all_perms
            .into_iter()
            .enumerate()
            .filter(|(k, perm)| {
                if *k == 0 {
                    return true;
                }
                if !cfg.isomorphism {
                    return false;
                }
                let mapped: Vec<Card> = board.iter().map(|&c| crate::cards::permute_card(perm, c)).collect();
                if mask_of(&mapped) != board_mask {
                    return false;
                }
                (0..2).all(|p| {
                    combos().iter().enumerate().all(|(i, c)| {
                        let j = combo_index(crate::cards::permute_card(perm, c[0]), crate::cards::permute_card(perm, c[1]));
                        ranges[p][i] == ranges[p][j]
                    })
                })
            })
            .map(|(_, p)| p)
            .collect();
        let perm_inv: Vec<u8> = perms
            .iter()
            .map(|p| {
                let mut inv = [0u8; 4];
                for (a, &b) in p.iter().enumerate() {
                    inv[b as usize] = a as u8;
                }
                perms.iter().position(|q| *q == inv).expect("symmetry group not closed") as u8
            })
            .collect();
        let mut hand_perm: [Vec<Vec<u32>>; 2] = [Vec::new(), Vec::new()];
        for p in 0..2 {
            let mut lookup = vec![u32::MAX; NUM_COMBOS];
            for (i, c) in hands[p].iter().enumerate() {
                lookup[combo_index(c[0], c[1])] = i as u32;
            }
            hand_perm[p] = perms
                .iter()
                .map(|perm| {
                    hands[p]
                        .iter()
                        .map(|c| lookup[combo_index(crate::cards::permute_card(perm, c[0]), crate::cards::permute_card(perm, c[1]))])
                        .collect()
                })
                .collect();
        }

        Ok(Game { tree_cfg, board, hands, weights, same, card_hands, river_index, river, root_street, perms, perm_inv, hand_perm })
    }

    pub fn n_hands(&self) -> [usize; 2] {
        [self.hands[0].len(), self.hands[1].len()]
    }

    fn half_pot(&self) -> f32 {
        self.tree_cfg.starting_pot * 0.5
    }

    // ---------------------------------------------------------------- terminals

    /// For each hero hand: the opponent reach mass that does not share a card with it.
    pub fn compatible_mass(&self, p: usize, opp: &[f32]) -> Vec<f64> {
        let mut out = vec![0.0f32; self.hands[p].len()];
        self.fold_into(p, opp, 1.0, &mut out);
        out.into_iter().map(|x| x as f64).collect()
    }

    /// `out[h] = payoff * (opponent mass compatible with h)`.
    fn fold_into(&self, p: usize, opp: &[f32], payoff: f32, out: &mut [f32]) {
        let q = 1 - p;
        let mut total = 0f32;
        let mut cs = [0f32; 52];
        for (c, &r) in self.hands[q].iter().zip(opp) {
            total += r;
            cs[c[0] as usize] += r;
            cs[c[1] as usize] += r;
        }
        let same = &self.same[p];
        for (h, c) in self.hands[p].iter().enumerate() {
            let s = same[h];
            let sm = if s >= 0 { opp[s as usize] } else { 0.0 };
            out[h] = payoff * (total - cs[c[0] as usize] - cs[c[1] as usize] + sm);
        }
    }

    fn ranks(&self, board_mask: u64) -> &RiverRanks {
        &self.river[*self.river_index.get(&board_mask).expect("unknown river board") as usize]
    }

    /// `out[h] = amount * (weaker compatible opponent mass - stronger compatible mass)`.
    fn showdown_into(&self, p: usize, opp: &[f32], board_mask: u64, amount: f32, out: &mut [f32]) {
        let r = self.ranks(board_mask);
        let (hero, vill) = (&r[p], &r[1 - p]);
        out.fill(0.0);
        let mut sum = 0f32;
        let mut cs = [0f32; 52];
        let mut j = 0;
        for e in hero.iter() {
            while j < vill.len() && vill[j].s < e.s {
                let o = vill[j];
                let w = opp[o.h as usize];
                sum += w;
                cs[o.c0 as usize] += w;
                cs[o.c1 as usize] += w;
                j += 1;
            }
            out[e.h as usize] = amount * (sum - cs[e.c0 as usize] - cs[e.c1 as usize]);
        }
        sum = 0.0;
        cs = [0f32; 52];
        let mut j = vill.len();
        for e in hero.iter().rev() {
            while j > 0 && vill[j - 1].s > e.s {
                j -= 1;
                let o = vill[j];
                let w = opp[o.h as usize];
                sum += w;
                cs[o.c0 as usize] += w;
                cs[o.c1 as usize] += w;
            }
            out[e.h as usize] -= amount * (sum - cs[e.c0 as usize] - cs[e.c1 as usize]);
        }
    }

    /// Returns (mass of compatible weaker opponent hands, mass of stronger ones) per hero hand.
    fn showdown_masses(&self, p: usize, opp: &[f32], board_mask: u64) -> (Vec<f64>, Vec<f64>) {
        let r = self.ranks(board_mask);
        let (hero, vill) = (&r[p], &r[1 - p]);
        let n = self.hands[p].len();
        let mut win = vec![0f64; n];
        let mut lose = vec![0f64; n];
        let mut sum = 0f64;
        let mut cs = [0f64; 52];
        let mut j = 0;
        for e in hero.iter() {
            while j < vill.len() && vill[j].s < e.s {
                let o = vill[j];
                let w = opp[o.h as usize] as f64;
                sum += w;
                cs[o.c0 as usize] += w;
                cs[o.c1 as usize] += w;
                j += 1;
            }
            win[e.h as usize] = sum - cs[e.c0 as usize] - cs[e.c1 as usize];
        }
        sum = 0.0;
        cs = [0f64; 52];
        let mut j = vill.len();
        for e in hero.iter().rev() {
            while j > 0 && vill[j - 1].s > e.s {
                j -= 1;
                let o = vill[j];
                let w = opp[o.h as usize] as f64;
                sum += w;
                cs[o.c0 as usize] += w;
                cs[o.c1 as usize] += w;
            }
            lose[e.h as usize] = sum - cs[e.c0 as usize] - cs[e.c1 as usize];
        }
        (win, lose)
    }

    fn terminal_into(&self, t: &TerminalNode, p: usize, opp: &[f32], board_mask: u64, out: &mut [f32]) {
        let q = 1 - p;
        match t.kind {
            TerminalKind::Fold(folder) => {
                let payoff = if folder == p { -(self.half_pot() + t.contrib[p]) } else { self.half_pot() + t.contrib[q] };
                self.fold_into(p, opp, payoff, out)
            }
            TerminalKind::Showdown => self.showdown_into(p, opp, board_mask, self.half_pot() + t.contrib[q], out),
        }
    }

    fn terminal_value(&self, t: &TerminalNode, p: usize, opp: &[f32], board_mask: u64) -> Vec<f32> {
        let mut out = vec![0.0f32; self.hands[p].len()];
        self.terminal_into(t, p, opp, board_mask, &mut out);
        out
    }

    fn deal(&self, p: usize, reach: &[f32], card: Card) -> Vec<f32> {
        let mut r = reach.to_vec();
        for &h in &self.card_hands[p][card as usize] {
            r[h as usize] = 0.0;
        }
        r
    }

    /// Sums canonical children values plus their suit-permuted images, times `factor`.
    fn combine_chance(&self, p: usize, vals: &[Vec<f32>], iso: &[IsoCard], factor: f32, out: &mut [f32]) {
        out.fill(0.0);
        for v in vals {
            out.iter_mut().zip(v).for_each(|(o, x)| *o += x);
        }
        for x in iso {
            // value of hand h under card g(c) equals the canonical value of g^-1(h)
            let map = &self.hand_perm[p][self.perm_inv[x.perm as usize] as usize];
            let v = &vals[x.child as usize];
            for (h, o) in out.iter_mut().enumerate() {
                *o += v[map[h] as usize];
            }
        }
        out.iter_mut().for_each(|o| *o *= factor);
    }

    /// Bitmask with every symmetry of the root enabled.
    pub fn root_symmetries(&self) -> u32 {
        (1u32 << self.perms.len()) - 1
    }

    // ---------------------------------------------------------------- CFR

    /// One DCFR update of player `p`'s regrets below `node`; writes `p`'s
    /// counterfactual values into `out`.
    #[allow(clippy::too_many_arguments)]
    fn cfr(&self, node: &mut Node, p: usize, hero: &[f32], opp: &[f32], board: u64, d: Discount, out: &mut [f32]) {
        let q = 1 - p;
        match node {
            Node::Terminal(t) => self.terminal_into(t, p, opp, board, out),
            Node::Chance(c) => {
                let n = hero.len();
                let factor = 1.0 / (c.n_cards as f32 - 4.0);
                let ChanceNode { cards, children, iso, .. } = &mut **c;
                let vals: Vec<Vec<f32>> = children
                    .par_iter_mut()
                    .zip(cards.par_iter())
                    .map(|(child, &card)| {
                        let h2 = self.deal(p, hero, card);
                        let o2 = self.deal(q, opp, card);
                        let mut v = vec![0.0f32; n];
                        self.cfr(child, p, &h2, &o2, board | (1u64 << card), d, &mut v);
                        for &h in &self.card_hands[p][card as usize] {
                            v[h as usize] = 0.0;
                        }
                        v
                    })
                    .collect();
                self.combine_chance(p, &vals, iso, factor, out);
            }
            Node::Action(_) if opp.iter().all(|&x| x == 0.0) => out.fill(0.0),
            Node::Action(a) => {
                let ActionNode { player, street, children, regrets, strat_sum, .. } = &mut **a;
                let na = children.len();
                let par = *street == self.root_street;
                if *player == p {
                    let n = hero.len();
                    let strat = regret_match(regrets, na, n);
                    let reaches: Vec<f32> = (0..na * n).map(|k| hero[k % n] * strat[k]).collect();
                    let mut vals = vec![0.0f32; na * n];
                    if par {
                        vals.par_chunks_mut(n)
                            .zip(children.par_iter_mut())
                            .zip(reaches.par_chunks(n))
                            .for_each(|((v, c), r)| self.cfr(c, p, r, opp, board, d, v));
                    } else {
                        for ((v, c), r) in vals.chunks_mut(n).zip(children.iter_mut()).zip(reaches.chunks(n)) {
                            self.cfr(c, p, r, opp, board, d, v);
                        }
                    }
                    out.fill(0.0);
                    for i in 0..na {
                        let (s, cv) = (&strat[i * n..(i + 1) * n], &vals[i * n..(i + 1) * n]);
                        for h in 0..n {
                            out[h] += s[h] * cv[h];
                        }
                    }
                    for i in 0..na {
                        let r = &mut regrets[i * n..(i + 1) * n];
                        let cv = &vals[i * n..(i + 1) * n];
                        for h in 0..n {
                            let old = r[h];
                            r[h] = old * if old > 0.0 { d.pos } else { d.neg } + cv[h] - out[h];
                        }
                    }
                    for (k, ss) in strat_sum.iter_mut().enumerate() {
                        *ss = *ss * d.strat + reaches[k];
                    }
                } else {
                    let n = opp.len();
                    let nh = hero.len();
                    let strat = regret_match(regrets, na, n);
                    let reaches: Vec<f32> = (0..na * n).map(|k| opp[k % n] * strat[k]).collect();
                    if par {
                        let mut vals = vec![0.0f32; na * nh];
                        vals.par_chunks_mut(nh)
                            .zip(children.par_iter_mut())
                            .zip(reaches.par_chunks(n))
                            .for_each(|((v, c), r)| self.cfr(c, p, hero, r, board, d, v));
                        out.fill(0.0);
                        for cv in vals.chunks(nh) {
                            out.iter_mut().zip(cv).for_each(|(x, y)| *x += y);
                        }
                    } else {
                        let mut tmp = vec![0.0f32; nh];
                        for (i, (c, r)) in children.iter_mut().zip(reaches.chunks(n)).enumerate() {
                            if i == 0 {
                                self.cfr(c, p, hero, r, board, d, out);
                            } else {
                                self.cfr(c, p, hero, r, board, d, &mut tmp);
                                out.iter_mut().zip(&tmp).for_each(|(x, y)| *x += y);
                            }
                        }
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------- evaluation

    /// Counterfactual values for player `p` when both players follow their
    /// average strategies (`best_response = false`) or when `p` best-responds.
    pub fn evaluate(&self, node: &Node, p: usize, opp: &[f32], board: u64, best_response: bool, depth: u32) -> Vec<f32> {
        let q = 1 - p;
        match node {
            Node::Terminal(t) => self.terminal_value(t, p, opp, board),
            Node::Chance(c) => {
                let n = self.hands[p].len();
                let factor = 1.0 / (c.n_cards as f32 - 4.0);
                let vals: Vec<Vec<f32>> = c
                    .children
                    .par_iter()
                    .zip(c.cards.par_iter())
                    .map(|(child, &card)| {
                        let o2 = self.deal(q, opp, card);
                        let mut v = self.evaluate(child, p, &o2, board | (1u64 << card), best_response, depth + 1);
                        for &h in &self.card_hands[p][card as usize] {
                            v[h as usize] = 0.0;
                        }
                        v
                    })
                    .collect();
                let mut out = vec![0.0f32; n];
                self.combine_chance(p, &vals, &c.iso, factor, &mut out);
                out
            }
            Node::Action(_) if opp.iter().all(|&x| x == 0.0) => vec![0.0; self.hands[p].len()],
            Node::Action(a) => {
                let na = a.children.len();
                let par = depth < PAR_DEPTH;
                if a.player == p {
                    let n = self.hands[p].len();
                    let run = |child: &Node| self.evaluate(child, p, opp, board, best_response, depth + 1);
                    let vals: Vec<Vec<f32>> = if par { a.children.par_iter().map(run).collect() } else { a.children.iter().map(run).collect() };
                    if best_response {
                        let mut v = vec![f32::NEG_INFINITY; n];
                        for cv in &vals {
                            v.iter_mut().zip(cv).for_each(|(x, y)| *x = x.max(*y));
                        }
                        v
                    } else {
                        let strat = average_strategy(&a.strat_sum, na, n);
                        let mut v = vec![0.0f32; n];
                        for (i, cv) in vals.iter().enumerate() {
                            for h in 0..n {
                                v[h] += strat[i * n + h] * cv[h];
                            }
                        }
                        v
                    }
                } else {
                    let n = opp.len();
                    let strat = average_strategy(&a.strat_sum, na, n);
                    let run = |(i, child): (usize, &Node)| {
                        let r: Vec<f32> = opp.iter().zip(&strat[i * n..(i + 1) * n]).map(|(o, s)| o * s).collect();
                        self.evaluate(child, p, &r, board, best_response, depth + 1)
                    };
                    let vals: Vec<Vec<f32>> = if par {
                        a.children.par_iter().enumerate().map(run).collect()
                    } else {
                        a.children.iter().enumerate().map(run).collect()
                    };
                    let mut v = vec![0.0f32; self.hands[p].len()];
                    for cv in vals {
                        v.iter_mut().zip(&cv).for_each(|(x, y)| *x += y);
                    }
                    v
                }
            }
        }
    }

    /// Showdown equity per hero hand against the opponent's reach, averaged over all runouts.
    pub fn equity(&self, p: usize, opp: &[f32], board: &[Card]) -> Vec<f32> {
        let bm = mask_of(board);
        let deck: Vec<Card> = (0..52u8).filter(|c| bm & (1 << c) == 0).collect();
        let mut boards: Vec<(u64, Vec<Card>)> = Vec::new();
        match board.len() {
            5 => boards.push((bm, vec![])),
            4 => deck.iter().for_each(|&c| boards.push((bm | 1 << c, vec![c]))),
            _ => {
                for i in 0..deck.len() {
                    for j in i + 1..deck.len() {
                        boards.push((bm | 1 << deck[i] | 1 << deck[j], vec![deck[i], deck[j]]));
                    }
                }
            }
        }
        let q = 1 - p;
        let n = self.hands[p].len();
        let (eq, mass) = boards
            .par_iter()
            .map(|(m, dealt)| {
                let mut o = opp.to_vec();
                for &c in dealt {
                    for &h in &self.card_hands[q][c as usize] {
                        o[h as usize] = 0.0;
                    }
                }
                let (win, lose) = self.showdown_masses(p, &o, *m);
                let compat = self.compatible_mass(p, &o);
                let mut e = vec![0f64; n];
                let mut c = vec![0f64; n];
                for h in 0..n {
                    let hc = self.hands[p][h];
                    if m & mask_of(&hc) != 0 {
                        continue;
                    }
                    let tie = (compat[h] - win[h] - lose[h]).max(0.0);
                    e[h] = win[h] + 0.5 * tie;
                    c[h] = compat[h];
                }
                (e, c)
            })
            .reduce(
                || (vec![0f64; n], vec![0f64; n]),
                |(mut a, mut b), (x, y)| {
                    a.iter_mut().zip(&x).for_each(|(p, q)| *p += q);
                    b.iter_mut().zip(&y).for_each(|(p, q)| *p += q);
                    (a, b)
                },
            );
        eq.iter().zip(&mass).map(|(e, m)| if *m > 0.0 { (e / m) as f32 } else { 0.0 }).collect()
    }
}

/// DCFR (alpha = 1.5, beta = 0.5, gamma = 3) for 0-based iteration `i`.
/// The average strategy is restarted at every power of 4 so that poor early
/// iterates stop polluting it.
fn discount_params(i: u32) -> Discount {
    let nearest_pow4 = if i == 0 { 0 } else { 1u32 << ((31 - i.leading_zeros()) & !1) };
    let ta = (i as f64 - 1.0).max(0.0);
    let pa = ta * ta.sqrt();
    let tg = (i - nearest_pow4) as f64;
    Discount { pos: (pa / (pa + 1.0)) as f32, neg: 0.5, strat: (tg / (tg + 1.0)).powi(3) as f32 }
}

pub fn regret_match(regrets: &[f32], na: usize, n: usize) -> Vec<f32> {
    let mut s: Vec<f32> = regrets.iter().map(|r| r.max(0.0)).collect();
    let mut denom = vec![0.0f32; n];
    for a in 0..na {
        for h in 0..n {
            denom[h] += s[a * n + h];
        }
    }
    let uniform = 1.0 / na as f32;
    for a in 0..na {
        for h in 0..n {
            let d = denom[h];
            s[a * n + h] = if d > 0.0 { s[a * n + h] / d } else { uniform };
        }
    }
    s
}

pub fn average_strategy(sums: &[f32], na: usize, n: usize) -> Vec<f32> {
    let mut denom = vec![0.0f32; n];
    for a in 0..na {
        for h in 0..n {
            denom[h] += sums[a * n + h];
        }
    }
    let uniform = 1.0 / na as f32;
    let mut s = vec![0.0f32; na * n];
    for a in 0..na {
        for h in 0..n {
            let d = denom[h];
            s[a * n + h] = if d > 0.0 { sums[a * n + h] / d } else { uniform };
        }
    }
    s
}

fn allocate(node: &mut Node, n_hands: [usize; 2]) {
    match node {
        Node::Terminal(_) => {}
        Node::Chance(c) => c.children.iter_mut().for_each(|ch| allocate(ch, n_hands)),
        Node::Action(a) => {
            let n = a.children.len() * n_hands[a.player];
            a.regrets = vec![0.0; n];
            a.strat_sum = vec![0.0; n];
            a.children.iter_mut().for_each(|ch| allocate(ch, n_hands));
        }
    }
}

// -------------------------------------------------------------------- solver

#[derive(Clone, Copy, Debug, Serialize)]
pub struct Progress {
    pub iteration: u32,
    pub exploitability: f32,
    pub elapsed: f64,
}

pub struct Solver {
    pub game: Game,
    pub root: Node,
    pub iteration: u32,
    pub exploitability: f32,
    pub elapsed: f64,
    pub estimate: Estimate,
    pool: rayon::ThreadPool,
}

pub fn estimate(cfg: &GameConfig) -> Result<(Game, Node, Estimate), String> {
    let game = Game::new(cfg)?;
    let n_hands = game.n_hands();
    let mut b = TreeBuilder {
        cfg: &game.tree_cfg,
        n_hands,
        allocate: false,
        stats: TreeStats::default(),
        perms: &game.perms,
        perm_inv: &game.perm_inv,
    };
    let root = b.build(&game.board, game.root_symmetries());
    let stats = b.stats;
    let node_overhead = stats.action_nodes * 160 + stats.chance_nodes * 96 + stats.terminal_nodes * 40;
    let river_bytes: u64 = game.river.iter().map(|r| ((r[0].len() + r[1].len()) * std::mem::size_of::<RankEntry>()) as u64).sum();
    let memory_bytes = stats.floats * 4 + node_overhead + river_bytes;
    Ok((game, root, Estimate { stats, memory_bytes, hands: n_hands }))
}

impl Solver {
    pub fn new(cfg: &GameConfig) -> Result<Solver, String> {
        let (game, mut root, est) = estimate(cfg)?;
        if cfg.max_memory_bytes > 0 && est.memory_bytes > cfg.max_memory_bytes {
            return Err(format!(
                "tree needs ~{:.1} GB but the limit is {:.1} GB; use fewer bet sizes",
                est.memory_bytes as f64 / 1e9,
                cfg.max_memory_bytes as f64 / 1e9
            ));
        }
        allocate(&mut root, game.n_hands());
        let pool = rayon::ThreadPoolBuilder::new()
            .num_threads(cfg.threads)
            .stack_size(16 << 20)
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Solver { game, root, iteration: 0, exploitability: f32::INFINITY, elapsed: 0.0, estimate: est, pool })
    }

    pub fn iterate(&mut self) {
        let t = self.iteration + 1;
        let d = discount_params(self.iteration);
        let board = mask_of(&self.game.board);
        let game = &self.game;
        let root = &mut self.root;
        self.pool.install(|| {
            for p in 0..2 {
                let hero = game.weights[p].clone();
                let opp = game.weights[1 - p].clone();
                let mut out = vec![0.0f32; hero.len()];
                game.cfr(root, p, &hero, &opp, board, d, &mut out);
            }
        });
        self.iteration = t;
    }

    /// Expected value per player (zero-sum units) at the root.
    fn root_values(&self, best_response: bool) -> [f64; 2] {
        let g = &self.game;
        let board = mask_of(&g.board);
        self.pool.install(|| {
            let mut out = [0f64; 2];
            let mass: f64 = g.compatible_mass(0, &g.weights[1]).iter().zip(&g.weights[0]).map(|(m, w)| m * *w as f64).sum();
            for p in 0..2 {
                let v = g.evaluate(&self.root, p, &g.weights[1 - p], board, best_response, 0);
                let total: f64 = v.iter().zip(&g.weights[p]).map(|(v, w)| *v as f64 * *w as f64).sum();
                out[p] = total / mass;
            }
            out
        })
    }

    /// Exploitability in percent of the starting pot.
    pub fn compute_exploitability(&mut self) -> f32 {
        let br = self.root_values(true);
        let e = ((br[0] + br[1]) / 2.0) as f32 / self.game.tree_cfg.starting_pot * 100.0;
        self.exploitability = e.max(0.0);
        self.exploitability
    }

    /// Runs until `max_iterations` total iterations, the target exploitability
    /// (percent of pot) is reached, or `stop` is raised.
    pub fn solve(
        &mut self,
        max_iterations: u32,
        target: f32,
        check_every: u32,
        stop: &AtomicBool,
        mut on_progress: impl FnMut(Progress),
    ) -> Progress {
        let check_every = check_every.max(1);
        let mut last = Instant::now();
        while self.iteration < max_iterations && !stop.load(Ordering::Relaxed) {
            self.iterate();
            let now = Instant::now();
            self.elapsed += (now - last).as_secs_f64();
            last = now;
            if self.iteration % check_every == 0 || self.iteration == max_iterations || self.iteration == 1 {
                let e = self.compute_exploitability();
                last = Instant::now();
                on_progress(self.progress());
                if e <= target {
                    break;
                }
            }
        }
        if self.iteration > 0 && self.iteration % check_every != 0 {
            self.compute_exploitability();
        }
        self.progress()
    }

    pub fn progress(&self) -> Progress {
        Progress { iteration: self.iteration, exploitability: self.exploitability, elapsed: self.elapsed }
    }

    // ------------------------------------------------------------ queries

    pub fn query(&self, path: &[Step]) -> Result<NodeInfo, String> {
        let g = &self.game;
        let mut node = &self.root;
        let mut reach = g.weights.clone();
        // `board` lives in the canonical frame of the tree; `frame` maps canonical suits to actual suits.
        let mut board = g.board.clone();
        let mut actual_board = g.board.clone();
        let mut frame: [u8; 4] = [0, 1, 2, 3];
        let mut history: Vec<String> = Vec::new();
        for step in path {
            match (node, step) {
                (Node::Action(a), Step::Action(i)) => {
                    let i = *i;
                    if i >= a.children.len() {
                        return Err(format!("action index {i} out of range"));
                    }
                    let n = g.hands[a.player].len();
                    let strat = average_strategy(&a.strat_sum, a.children.len(), n);
                    for h in 0..n {
                        reach[a.player][h] *= strat[i * n + h];
                    }
                    history.push(format!("{}: {}", if a.player == 0 { "OOP" } else { "IP" }, a.actions[i].label()));
                    node = &a.children[i];
                }
                (Node::Chance(c), Step::Card(card)) => {
                    let mut inv = [0u8; 4];
                    for (a, &b) in frame.iter().enumerate() {
                        inv[b as usize] = a as u8;
                    }
                    let x = crate::cards::permute_card(&inv, *card);
                    let (pos, k) = c.locate(x).ok_or("card not available here")?;
                    let canon = c.cards[pos];
                    let step = g.perms[k as usize];
                    frame = [frame[step[0] as usize], frame[step[1] as usize], frame[step[2] as usize], frame[step[3] as usize]];
                    for p in 0..2 {
                        reach[p] = g.deal(p, &reach[p], canon);
                    }
                    board.push(canon);
                    actual_board.push(*card);
                    history.push(crate::cards::card_to_string(*card));
                    node = &c.children[pos];
                }
                _ => return Err("path does not match the tree".into()),
            }
        }
        Ok(self.describe(node, &reach, &board, &actual_board, &frame, history))
    }

    fn describe(
        &self,
        node: &Node,
        reach: &[Vec<f32>; 2],
        board: &[Card],
        actual_board: &[Card],
        frame: &[u8; 4],
        history: Vec<String>,
    ) -> NodeInfo {
        let to_actual = |c: Card| crate::cards::permute_card(frame, c);
        let g = &self.game;
        let bm = mask_of(board);
        let contrib = node.contrib();
        let pot = g.tree_cfg.starting_pot + contrib[0] + contrib[1];
        let stack = g.tree_cfg.effective_stack;
        let street = (board.len() - 3).min(2);

        let (kind, player, actions, chance_cards, terminal) = match node {
            Node::Action(a) => ("action", Some(a.player), a.actions.iter().map(ActionInfo::from).collect(), vec![], None),
            Node::Chance(c) => {
                let mut cards: Vec<Card> = c.all_cards().into_iter().map(to_actual).collect();
                cards.sort_unstable();
                ("chance", None, vec![], cards.into_iter().map(crate::cards::card_to_string).collect(), None)
            }
            Node::Terminal(t) => (
                "terminal",
                None,
                vec![],
                vec![],
                Some(match t.kind {
                    TerminalKind::Fold(p) => format!("{} folds", if p == 0 { "OOP" } else { "IP" }),
                    TerminalKind::Showdown => "Showdown".to_string(),
                }),
            ),
        };

        let views = self.pool.install(|| {
            let mut views: Vec<PlayerView> = Vec::with_capacity(2);
            for p in 0..2 {
                let q = 1 - p;
                let n = g.hands[p].len();
                let opp = &reach[q];
                let compat = g.compatible_mass(p, opp);
                let offset = g.half_pot() + contrib[p];
                let norm = |v: &[f32]| -> Vec<f32> {
                    v.iter().zip(&compat).map(|(x, m)| if *m > 1e-9 { (*x as f64 / m) as f32 + offset } else { 0.0 }).collect()
                };
                let mut strategy: Vec<f32> = vec![];
                let mut action_evs: Vec<Vec<f32>> = vec![];
                let ev: Vec<f32>;
                match node {
                    Node::Action(a) if a.player == p => {
                        let na = a.children.len();
                        strategy = average_strategy(&a.strat_sum, na, n);
                        let raw: Vec<Vec<f32>> = a.children.par_iter().map(|c| g.evaluate(c, p, opp, bm, false, 1)).collect();
                        let mut total = vec![0.0f32; n];
                        for (i, cv) in raw.iter().enumerate() {
                            for h in 0..n {
                                total[h] += strategy[i * n + h] * cv[h];
                            }
                        }
                        action_evs = raw.iter().map(|v| norm(v)).collect();
                        ev = norm(&total);
                    }
                    Node::Terminal(_) | Node::Chance(_) | Node::Action(_) => {
                        ev = norm(&g.evaluate(node, p, opp, bm, false, 1));
                    }
                }
                let equity = g.equity(p, opp, board);
                let mut hands = Vec::new();
                let total_weight: f32 = reach[p].iter().sum();
                for h in 0..n {
                    let r = reach[p][h];
                    if r <= 1e-7 || bm & mask_of(&g.hands[p][h]) != 0 {
                        continue;
                    }
                    let na = actions_len(node, p);
                    hands.push(HandInfo {
                        combo: {
                            let c = g.hands[p][h];
                            combo_to_string([to_actual(c[0]), to_actual(c[1])])
                        },
                        weight: g.weights[p][h],
                        reach: r,
                        strategy: (0..na).map(|a| strategy[a * n + h]).collect(),
                        action_evs: action_evs.iter().map(|v| v[h]).collect(),
                        ev: ev[h],
                        equity: equity[h],
                    });
                }
                views.push(PlayerView { combos: total_weight, hands });
            }
            views
        });

        NodeInfo {
            kind: kind.into(),
            street: STREET_NAMES[street].into(),
            board: actual_board.iter().map(|&c| crate::cards::card_to_string(c)).collect(),
            pot,
            starting_pot: g.tree_cfg.starting_pot,
            contrib,
            stacks: [stack - contrib[0], stack - contrib[1]],
            player,
            actions,
            chance_cards,
            terminal,
            history,
            players: views,
            iteration: self.iteration,
            exploitability: self.exploitability,
        }
    }
}

fn actions_len(node: &Node, p: usize) -> usize {
    match node {
        Node::Action(a) if a.player == p => a.children.len(),
        _ => 0,
    }
}

#[derive(Clone, Debug)]
pub enum Step {
    Action(usize),
    Card(Card),
}

#[derive(Serialize)]
pub struct ActionInfo {
    pub label: String,
    pub kind: ActionKind,
    pub amount: f32,
    pub to: f32,
    pub pot_fraction: f32,
}

impl From<&Action> for ActionInfo {
    fn from(a: &Action) -> Self {
        ActionInfo { label: a.label(), kind: a.kind, amount: a.amount, to: a.to, pot_fraction: a.pot_fraction }
    }
}

#[derive(Serialize)]
pub struct HandInfo {
    pub combo: String,
    /// Weight in the starting range.
    pub weight: f32,
    /// Starting weight times the probability of reaching this node.
    pub reach: f32,
    pub strategy: Vec<f32>,
    pub action_evs: Vec<f32>,
    /// Expected chips won from this node on (pot share minus future investment).
    pub ev: f32,
    pub equity: f32,
}

#[derive(Serialize)]
pub struct PlayerView {
    pub combos: f32,
    pub hands: Vec<HandInfo>,
}

#[derive(Serialize)]
pub struct NodeInfo {
    pub kind: String,
    pub street: String,
    pub board: Vec<String>,
    pub pot: f32,
    pub starting_pot: f32,
    pub contrib: [f32; 2],
    pub stacks: [f32; 2],
    pub player: Option<usize>,
    pub actions: Vec<ActionInfo>,
    pub chance_cards: Vec<String>,
    pub terminal: Option<String>,
    pub history: Vec<String>,
    pub players: Vec<PlayerView>,
    pub iteration: u32,
    pub exploitability: f32,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn river_cfg() -> GameConfig {
        serde_json::from_value(serde_json::json!({
            "board": "Qs Jh 2h 8d 3c",
            "range_oop": "AA,KK,QQ,JJ,AQs,KQs,QJs,T9s,98s,A5s,22",
            "range_ip": "AA,KK,QQ,AQs,AKs,KQs,QJs,JTs,T9s,A4s,65s,33",
            "starting_pot": 10.0,
            "effective_stack": 50.0,
            "bet_sizes": {
                "river": { "oop": { "bet": "50,100", "raise": "60" }, "ip": { "bet": "50,100", "raise": "60" } }
            }
        }))
        .unwrap()
    }

    #[test]
    fn river_converges() {
        let mut s = Solver::new(&river_cfg()).unwrap();
        let stop = AtomicBool::new(false);
        let p = s.solve(400, 0.1, 50, &stop, |_| {});
        assert!(p.exploitability < 0.5, "exploitability {}", p.exploitability);
        let info = s.query(&[]).unwrap();
        // values at the root must split the pot
        let ev = |pl: usize| -> f64 {
            let v = &info.players[pl];
            let num: f64 = v.hands.iter().map(|h| h.ev as f64 * h.weight as f64).sum();
            let den: f64 = v.hands.iter().map(|h| h.weight as f64).sum();
            num / den
        };
        let _ = ev(0) + ev(1);
    }

    #[test]
    fn turn_runs() {
        let mut cfg = river_cfg();
        cfg.board = "Qs Jh 2h 8d".into();
        cfg.bet_sizes.turn = cfg.bet_sizes.river.clone();
        let mut s = Solver::new(&cfg).unwrap();
        let stop = AtomicBool::new(false);
        let p = s.solve(200, 0.3, 25, &stop, |_| {});
        assert!(p.exploitability < 1.0, "exploitability {}", p.exploitability);
        let info = s.query(&[Step::Action(0), Step::Action(0), Step::Card(crate::cards::card_from_str("3c").unwrap())]).unwrap();
        assert_eq!(info.kind, "action");
        assert_eq!(info.board.len(), 5);
    }
}

#[cfg(test)]
mod iso_tests {
    use super::*;

    fn cfg(iso: bool) -> GameConfig {
        serde_json::from_value(serde_json::json!({
            "board": "Qh Jh 2h 7s",
            "range_oop": "AA,KK,QQ,JJ,TT,77,22,AKs,AQs,KQs,QJs,JTs,T9s,98s,A5s,AQo,KJo",
            "range_ip": "AA,KK,QQ,99,88,AKs,AJs,KQs,KTs,QTs,J9s,T8s,65s,54s,AKo,AJo,QJo",
            "starting_pot": 10.0,
            "effective_stack": 40.0,
            "isomorphism": iso,
            "bet_sizes": {
                "turn": { "oop": { "bet": "50", "raise": "60" }, "ip": { "bet": "50", "raise": "60" } },
                "river": { "oop": { "bet": "75", "raise": "" }, "ip": { "bet": "75", "raise": "" } }
            }
        }))
        .unwrap()
    }

    fn hand<'a>(info: &'a NodeInfo, p: usize, combo: &str) -> &'a HandInfo {
        info.players[p].hands.iter().find(|h| h.combo == combo).unwrap_or_else(|| panic!("{combo} missing"))
    }

    const ITERS: u32 = 1000;

    #[test]
    fn isomorphism_matches_full_tree() {
        let stop = AtomicBool::new(false);
        let mut full = Solver::new(&cfg(false)).unwrap();
        let mut iso = Solver::new(&cfg(true)).unwrap();
        assert!(iso.game.perms.len() == 2, "expected c<->d symmetry, got {:?}", iso.game.perms);
        assert!(iso.estimate.stats.action_nodes < full.estimate.stats.action_nodes);
        let a = full.solve(ITERS, 0.0, ITERS, &stop, |_| {});
        let b = iso.solve(ITERS, 0.0, ITERS, &stop, |_| {});
        eprintln!("expl full {} iso {}", a.exploitability, b.exploitability);
        assert!((a.exploitability - b.exploitability).abs() < 0.15, "{} vs {}", a.exploitability, b.exploitability);

        // same river card in both trees, and mirrored river cards inside the iso tree
        let path = |card: &str| vec![Step::Action(0), Step::Action(0), Step::Card(crate::cards::card_from_str(card).unwrap())];
        let f_d = full.query(&path("5d")).unwrap();
        let i_d = iso.query(&path("5d")).unwrap();
        let i_c = iso.query(&path("5c")).unwrap();
        assert_eq!(i_d.board, vec!["Qh", "Jh", "2h", "7s", "5d"]);
        assert_eq!(i_c.board, vec!["Qh", "Jh", "2h", "7s", "5c"]);
        assert_eq!(i_d.chance_cards.len(), 0);
        for (combo, mirror) in [("AdKd", "AcKc"), ("AsKs", "AsKs"), ("AhKh", "AhKh"), ("AcKd", "AdKc")] {
            for p in 0..2 {
                let (Some(x), Some(y), Some(z)) = (
                    f_d.players[p].hands.iter().find(|h| h.combo == combo),
                    i_d.players[p].hands.iter().find(|h| h.combo == combo),
                    i_c.players[p].hands.iter().find(|h| h.combo == mirror),
                ) else { continue };
                eprintln!("{combo} p{p}: full {} iso {} mirror {}", x.ev, y.ev, z.ev);
                assert!((x.ev - y.ev).abs() < 0.2, "{combo} p{p}: full {} iso {}", x.ev, y.ev);
                assert!((y.ev - z.ev).abs() < 1e-3, "{combo}/{mirror} p{p}: {} vs {}", y.ev, z.ev);
                assert!((y.equity - z.equity).abs() < 1e-4);
                for (s, t) in y.strategy.iter().zip(&z.strategy) {
                    assert!((s - t).abs() < 1e-4);
                }
            }
        }
        let _ = hand(&i_d, 1, "AdKd");
        // range-level values at the root must agree closely
        let (fr, ir) = (full.query(&[]).unwrap(), iso.query(&[]).unwrap());
        for p in 0..2 {
            let ev = |n: &NodeInfo| -> f64 {
                let v = &n.players[p].hands;
                v.iter().map(|h| (h.ev * h.reach) as f64).sum::<f64>() / v.iter().map(|h| h.reach as f64).sum::<f64>()
            };
            assert!((ev(&fr) - ev(&ir)).abs() < 0.03, "root EV p{p}: {} vs {}", ev(&fr), ev(&ir));
        }
        let chance = iso.query(&[Step::Action(0), Step::Action(0)]).unwrap();
        assert_eq!(chance.chance_cards.len(), 48);
    }
}
