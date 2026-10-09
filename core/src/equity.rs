//! Monte-Carlo equity of a concrete hand against a weighted range.

use crate::cards::{combos, mask_of, Card};
use crate::eval::eval;

pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Rng(seed ^ 0x9E37_79B9_7F4A_7C15)
    }
    pub fn next(&mut self) -> u64 {
        // splitmix64
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    pub fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
    pub fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }
}

pub fn monte_carlo(hand: &[Card], board: &[Card], range: &[f32], samples: usize) -> Result<f64, String> {
    if hand.len() != 2 {
        return Err("hand must have two cards".into());
    }
    if board.len() > 5 {
        return Err("board has too many cards".into());
    }
    let dead = mask_of(hand) | mask_of(board);
    if dead.count_ones() as usize != hand.len() + board.len() {
        return Err("duplicate cards".into());
    }
    // cumulative weights over villain combos that don't collide with known cards
    let mut cands: Vec<([Card; 2], f64)> = Vec::new();
    let mut acc = 0.0;
    for (i, c) in combos().iter().enumerate() {
        if range[i] > 0.0 && dead & mask_of(c) == 0 {
            acc += range[i] as f64;
            cands.push((*c, acc));
        }
    }
    if cands.is_empty() {
        return Err("villain range is empty given the known cards".into());
    }
    let mut rng = Rng::new(dead.wrapping_mul(31).wrapping_add(samples as u64));
    let mut total = 0.0;
    let mut hero7 = [0u8; 7];
    let mut vill7 = [0u8; 7];
    for _ in 0..samples.max(1) {
        let x = rng.unit() * acc;
        let k = cands.partition_point(|(_, w)| *w < x).min(cands.len() - 1);
        let v = cands[k].0;
        let mut used = dead | mask_of(&v);
        let mut b: Vec<Card> = board.to_vec();
        while b.len() < 5 {
            let c = rng.below(52) as Card;
            if used & (1 << c) == 0 {
                used |= 1 << c;
                b.push(c);
            }
        }
        hero7[..5].copy_from_slice(&b);
        vill7[..5].copy_from_slice(&b);
        hero7[5] = hand[0];
        hero7[6] = hand[1];
        vill7[5] = v[0];
        vill7[6] = v[1];
        let (h, w) = (eval(&hero7), eval(&vill7));
        total += if h > w { 1.0 } else if h == w { 0.5 } else { 0.0 };
    }
    Ok(total / samples.max(1) as f64)
}
