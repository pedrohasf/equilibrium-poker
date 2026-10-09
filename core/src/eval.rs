//! Bitmask hand evaluator for 5..7 cards. Higher value = stronger hand.
//! Layout: category << 24 | rank nibbles (most significant first).

use crate::cards::Card;

pub const HIGH_CARD: u32 = 0;
pub const PAIR: u32 = 1;
pub const TWO_PAIR: u32 = 2;
pub const TRIPS: u32 = 3;
pub const STRAIGHT: u32 = 4;
pub const FLUSH: u32 = 5;
pub const FULL_HOUSE: u32 = 6;
pub const QUADS: u32 = 7;
pub const STRAIGHT_FLUSH: u32 = 8;

pub const CATEGORY_NAMES: [&str; 9] = [
    "High card",
    "Pair",
    "Two pair",
    "Trips",
    "Straight",
    "Flush",
    "Full house",
    "Quads",
    "Straight flush",
];

#[inline]
fn hi(m: u16) -> u32 {
    15 - m.leading_zeros()
}

/// Packs the `n` highest ranks of `m` into nibbles, highest first.
#[inline]
fn top_n(mut m: u16, n: u32) -> u32 {
    let mut v = 0u32;
    for _ in 0..n {
        v <<= 4;
        if m != 0 {
            let r = hi(m);
            v |= r;
            m &= !(1 << r);
        }
    }
    v
}

/// Returns a unique ordinal for the highest straight in a 13-bit rank mask.
#[inline]
fn straight_top(m: u16) -> Option<u32> {
    let x: u32 = ((m as u32) << 1) | ((m as u32 >> 12) & 1);
    let s = x & (x >> 1) & (x >> 2) & (x >> 3) & (x >> 4);
    if s == 0 {
        None
    } else {
        Some(31 - s.leading_zeros())
    }
}

pub fn eval(cards: &[Card]) -> u32 {
    let mut sm = [0u16; 4];
    for &c in cards {
        sm[(c & 3) as usize] |= 1 << (c >> 2);
    }
    for &m in &sm {
        if m.count_ones() >= 5 {
            if let Some(t) = straight_top(m) {
                return (STRAIGHT_FLUSH << 24) | t;
            }
            return (FLUSH << 24) | top_n(m, 5);
        }
    }
    let all = sm[0] | sm[1] | sm[2] | sm[3];
    let quads = sm[0] & sm[1] & sm[2] & sm[3];
    if quads != 0 {
        let q = hi(quads);
        return (QUADS << 24) | (q << 4) | top_n(all & !(1 << q), 1);
    }
    // ranks seen at least twice / three times
    let ge2 = (sm[0] & sm[1]) | (sm[0] & sm[2]) | (sm[0] & sm[3]) | (sm[1] & sm[2]) | (sm[1] & sm[3]) | (sm[2] & sm[3]);
    let ge3 = (sm[0] & sm[1] & sm[2]) | (sm[0] & sm[1] & sm[3]) | (sm[0] & sm[2] & sm[3]) | (sm[1] & sm[2] & sm[3]);
    if ge3 != 0 {
        let t = hi(ge3);
        let rest = ge2 & !(1 << t);
        if rest != 0 {
            return (FULL_HOUSE << 24) | (t << 4) | hi(rest);
        }
    }
    if let Some(t) = straight_top(all) {
        return (STRAIGHT << 24) | t;
    }
    if ge3 != 0 {
        let t = hi(ge3);
        return (TRIPS << 24) | (t << 8) | top_n(all & !(1 << t), 2);
    }
    if ge2.count_ones() >= 2 {
        let p1 = hi(ge2);
        let p2 = hi(ge2 & !(1 << p1));
        return (TWO_PAIR << 24) | (p1 << 8) | (p2 << 4) | top_n(all & !(1 << p1) & !(1 << p2), 1);
    }
    if ge2 != 0 {
        let p = hi(ge2);
        return (PAIR << 24) | (p << 12) | top_n(all & !(1 << p), 3);
    }
    (HIGH_CARD << 24) | top_n(all, 5)
}

pub fn category(value: u32) -> u32 {
    value >> 24
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cards::parse_cards;

    fn e(s: &str) -> u32 {
        eval(&parse_cards(s).unwrap())
    }

    #[test]
    fn categories() {
        assert_eq!(category(e("AsKsQsJsTs2c3d")), STRAIGHT_FLUSH);
        assert_eq!(category(e("As2s3s4s5s9c9d")), STRAIGHT_FLUSH);
        assert_eq!(category(e("AsAhAdAc2c3d4h")), QUADS);
        assert_eq!(category(e("AsAhAdKcKd3d4h")), FULL_HOUSE);
        assert_eq!(category(e("AsAhAdKcKdKh4h")), FULL_HOUSE);
        assert_eq!(category(e("2s7s9sJsKs3d4h")), FLUSH);
        assert_eq!(category(e("As2d3h4c5s9d9h")), STRAIGHT);
        assert_eq!(category(e("7s7d7h2c5sJdKh")), TRIPS);
        assert_eq!(category(e("7s7d2h2c5s5dKh")), TWO_PAIR);
        assert_eq!(category(e("7s7d2h3c5sJdKh")), PAIR);
        assert_eq!(category(e("7s8d2h3c5sJdKh")), HIGH_CARD);
    }

    #[test]
    fn ordering() {
        assert!(e("As2d3h4c5s9d9h") < e("2s3d4h5c6s9d9h")); // wheel < six-high
        assert!(e("7s7d2h2c5s5dKh") == e("7s7d5h5c2s4dKh")); // kicker K both
        assert!(e("AsAd2h2c5s5dKh") > e("KsKdQhQc5s5dAh"));
        assert!(e("AsKd9h7c5s3d2h") > e("AsKd9h7c4s3d2h"));
        assert!(e("TsTdThJcJd9h9s") > e("9s9d9hAcAdKhKs"));
    }
}
